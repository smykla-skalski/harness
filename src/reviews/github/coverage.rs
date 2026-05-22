use super::ReviewItem;

pub(super) fn log_check_details_url_coverage(items: &[ReviewItem]) {
    CheckDetailsUrlCoverage::from_items(items).log(items.len());
}

struct CheckDetailsUrlCoverage {
    check_count: usize,
    missing_details_url_count: usize,
}

impl CheckDetailsUrlCoverage {
    fn from_items(items: &[ReviewItem]) -> Self {
        let (check_count, missing_details_url_count) = check_details_url_counts(items);
        Self {
            check_count,
            missing_details_url_count,
        }
    }

    #[allow(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion overstates this straight-line logging helper"
    )]
    fn log(&self, review_count: usize) {
        if self.check_count == 0 {
            return;
        }
        tracing::debug!(
            "reviews check details URL coverage: {review_count} updates, {} checks, {} missing details URLs",
            self.check_count,
            self.missing_details_url_count
        );
    }
}

fn check_details_url_counts(items: &[ReviewItem]) -> (usize, usize) {
    items.iter().flat_map(|item| &item.checks).fold(
        (0, 0),
        |(check_count, missing_count), check| {
            (
                check_count + 1,
                missing_count + usize::from(check.details_url.is_none()),
            )
        },
    )
}
