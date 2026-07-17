use chrono::{
    DateTime, Datelike, Days, Duration, LocalResult, NaiveDate, NaiveDateTime, NaiveTime,
    SecondsFormat, TimeZone, Utc, Weekday,
};
use chrono_tz::Tz;

use super::policy_compiler::{
    PolicyRule, PolicyRuleKey, PolicyRuleValue, ResolvedScope, TaskBoardOutsideWindowAction,
    TaskBoardPolicyCompilationError, TaskBoardPolicyWeekday, TaskBoardPolicyWindow,
};
use crate::task_board::{TaskBoardAdmissionRequirement, TaskBoardAdmissionRequirementKind};

pub(super) fn policy_window_rule(
    window: &TaskBoardPolicyWindow,
    scope: ResolvedScope,
) -> Result<PolicyRule, TaskBoardPolicyCompilationError> {
    let resolved = ResolvedWindowPolicy::new(window, scope)?;
    Ok(PolicyRule {
        key: PolicyRuleKey::Window {
            scope: resolved.scope.key(),
            signature: resolved.signature(),
        },
        value: PolicyRuleValue::Window {
            outside_action: resolved.outside_action,
        },
    })
}

pub(super) fn compile_policy_window(
    window: &TaskBoardPolicyWindow,
    scope: ResolvedScope,
    evaluated_at: Option<DateTime<Utc>>,
) -> Result<Option<TaskBoardAdmissionRequirement>, TaskBoardPolicyCompilationError> {
    let resolved = ResolvedWindowPolicy::new(window, scope)?;
    evaluated_at
        .map(|value| resolved.compile_requirement(value))
        .transpose()
}

struct ResolvedWindowPolicy {
    scope: ResolvedScope,
    timezone: Tz,
    weekdays: Vec<TaskBoardPolicyWeekday>,
    start_time: NaiveTime,
    end_time: NaiveTime,
    outside_action: TaskBoardOutsideWindowAction,
}

impl ResolvedWindowPolicy {
    fn new(
        window: &TaskBoardPolicyWindow,
        scope: ResolvedScope,
    ) -> Result<Self, TaskBoardPolicyCompilationError> {
        let scope_key = scope.key();
        let timezone = window.timezone.trim().parse::<Tz>().map_err(|_| {
            TaskBoardPolicyCompilationError::InvalidTimezone {
                scope: scope_key.clone(),
                timezone: window.timezone.clone(),
            }
        })?;
        let mut weekdays = window.weekdays.clone();
        weekdays.sort_unstable();
        weekdays.dedup();
        if weekdays.is_empty() {
            return Err(TaskBoardPolicyCompilationError::EmptyWeekdays { scope: scope_key });
        }
        let start_time = parse_local_time(&window.start_time, &scope)?;
        let end_time = parse_local_time(&window.end_time, &scope)?;
        if start_time == end_time {
            return Err(TaskBoardPolicyCompilationError::ZeroLengthWindow { scope: scope.key() });
        }
        Ok(Self {
            scope,
            timezone,
            weekdays,
            start_time,
            end_time,
            outside_action: window.outside_action,
        })
    }

    fn signature(&self) -> String {
        let weekdays = self
            .weekdays
            .iter()
            .map(|weekday| weekday_name(*weekday))
            .collect::<Vec<_>>()
            .join(",");
        format!(
            "{}|{weekdays}|{}|{}",
            self.timezone,
            self.start_time.format("%H:%M"),
            self.end_time.format("%H:%M")
        )
    }

    fn compile_requirement(
        &self,
        evaluated_at: DateTime<Utc>,
    ) -> Result<TaskBoardAdmissionRequirement, TaskBoardPolicyCompilationError> {
        let occurrences = self.occurrences(evaluated_at)?;
        let selected = occurrences
            .iter()
            .find(|window| window.start <= evaluated_at && evaluated_at < window.end)
            .or_else(|| self.select_closed_occurrence(&occurrences, evaluated_at))
            .ok_or_else(|| TaskBoardPolicyCompilationError::UnresolvableWindow {
                scope: self.scope.key(),
            })?;
        let duration = selected
            .end
            .signed_duration_since(selected.start)
            .num_seconds();
        let window_seconds = u64::try_from(duration).map_err(|_| {
            TaskBoardPolicyCompilationError::UnresolvableWindow {
                scope: self.scope.key(),
            }
        })?;
        Ok(TaskBoardAdmissionRequirement {
            kind: TaskBoardAdmissionRequirementKind::TimeWindow,
            scope: self.scope.key(),
            limit: 1,
            window_seconds: Some(window_seconds),
            reservation: Some(1),
            available_at: Some(canonical_time(selected.start)),
        })
    }

    fn select_closed_occurrence<'a>(
        &self,
        occurrences: &'a [WindowOccurrence],
        evaluated_at: DateTime<Utc>,
    ) -> Option<&'a WindowOccurrence> {
        match self.outside_action {
            TaskBoardOutsideWindowAction::Defer => occurrences
                .iter()
                .filter(|window| window.start > evaluated_at)
                .min_by_key(|window| window.start),
            TaskBoardOutsideWindowAction::Deny => occurrences
                .iter()
                .filter(|window| window.end <= evaluated_at)
                .max_by_key(|window| window.end),
        }
    }

    fn occurrences(
        &self,
        evaluated_at: DateTime<Utc>,
    ) -> Result<Vec<WindowOccurrence>, TaskBoardPolicyCompilationError> {
        let local_date = evaluated_at.with_timezone(&self.timezone).date_naive();
        let mut occurrences = Vec::new();
        for offset in -8_i32..=8 {
            let Some(date) = offset_date(local_date, offset) else {
                continue;
            };
            if !self
                .weekdays
                .iter()
                .any(|weekday| weekday.matches(date.weekday()))
            {
                continue;
            }
            occurrences.push(self.occurrence(date)?);
        }
        Ok(occurrences)
    }

    fn occurrence(
        &self,
        date: NaiveDate,
    ) -> Result<WindowOccurrence, TaskBoardPolicyCompilationError> {
        let end_date = if self.end_time <= self.start_time {
            date.checked_add_days(Days::new(1))
        } else {
            Some(date)
        }
        .ok_or_else(|| TaskBoardPolicyCompilationError::UnresolvableWindow {
            scope: self.scope.key(),
        })?;
        let start =
            resolve_local_boundary(self.timezone, date.and_time(self.start_time), &self.scope)?;
        let end =
            resolve_local_boundary(self.timezone, end_date.and_time(self.end_time), &self.scope)?;
        let (start, end) = fail_closed_interval(start, end).ok_or_else(|| {
            TaskBoardPolicyCompilationError::UnresolvableWindow {
                scope: self.scope.key(),
            }
        })?;
        Ok(WindowOccurrence { start, end })
    }
}

#[derive(Debug, Clone, Copy)]
struct WindowOccurrence {
    start: DateTime<Utc>,
    end: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy)]
struct ResolvedBoundary {
    earliest: DateTime<Utc>,
    latest: DateTime<Utc>,
}

impl TaskBoardPolicyWeekday {
    const fn matches(self, weekday: Weekday) -> bool {
        matches!(
            (self, weekday),
            (Self::Monday, Weekday::Mon)
                | (Self::Tuesday, Weekday::Tue)
                | (Self::Wednesday, Weekday::Wed)
                | (Self::Thursday, Weekday::Thu)
                | (Self::Friday, Weekday::Fri)
                | (Self::Saturday, Weekday::Sat)
                | (Self::Sunday, Weekday::Sun)
        )
    }
}

fn parse_local_time(
    value: &str,
    scope: &ResolvedScope,
) -> Result<NaiveTime, TaskBoardPolicyCompilationError> {
    NaiveTime::parse_from_str(value.trim(), "%H:%M").map_err(|_| {
        TaskBoardPolicyCompilationError::InvalidLocalTime {
            scope: scope.key(),
            value: value.to_owned(),
        }
    })
}

fn offset_date(date: NaiveDate, offset: i32) -> Option<NaiveDate> {
    if offset.is_negative() {
        date.checked_sub_days(Days::new(u64::from(offset.unsigned_abs())))
    } else {
        date.checked_add_days(Days::new(u64::from(offset.unsigned_abs())))
    }
}

// A fold can map to disjoint UTC intervals. Choose the narrowest valid pair,
// preferring the later start, so ambiguous local time fails closed.
fn fail_closed_interval(
    start: ResolvedBoundary,
    end: ResolvedBoundary,
) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
    [
        (start.latest, end.earliest),
        (start.latest, end.latest),
        (start.earliest, end.earliest),
    ]
    .into_iter()
    .find(|(start, end)| end > start)
}

// A gap advances to the first valid local minute, bounded well past real DST
// transitions while still failing closed for corrupt timezone data.
fn resolve_local_boundary(
    timezone: Tz,
    local: NaiveDateTime,
    scope: &ResolvedScope,
) -> Result<ResolvedBoundary, TaskBoardPolicyCompilationError> {
    for minute in 0_i64..=180 {
        let Some(candidate) = local.checked_add_signed(Duration::minutes(minute)) else {
            break;
        };
        match timezone.from_local_datetime(&candidate) {
            LocalResult::Single(value) => {
                let value = value.with_timezone(&Utc);
                return Ok(ResolvedBoundary {
                    earliest: value,
                    latest: value,
                });
            }
            LocalResult::Ambiguous(first, second) => {
                return Ok(ResolvedBoundary {
                    earliest: first.min(second).with_timezone(&Utc),
                    latest: first.max(second).with_timezone(&Utc),
                });
            }
            LocalResult::None => {}
        }
    }
    Err(TaskBoardPolicyCompilationError::UnresolvableWindow { scope: scope.key() })
}

const fn weekday_name(weekday: TaskBoardPolicyWeekday) -> &'static str {
    match weekday {
        TaskBoardPolicyWeekday::Monday => "monday",
        TaskBoardPolicyWeekday::Tuesday => "tuesday",
        TaskBoardPolicyWeekday::Wednesday => "wednesday",
        TaskBoardPolicyWeekday::Thursday => "thursday",
        TaskBoardPolicyWeekday::Friday => "friday",
        TaskBoardPolicyWeekday::Saturday => "saturday",
        TaskBoardPolicyWeekday::Sunday => "sunday",
    }
}

fn canonical_time(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::AutoSi, true)
}
