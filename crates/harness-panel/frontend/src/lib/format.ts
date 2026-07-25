/**
 * Render an RFC 3339 timestamp for a person reading the page.
 *
 * The panel stores timestamps in UTC and the browser knows the reader's zone,
 * so the conversion belongs here rather than in the API. A value the browser
 * cannot parse is shown verbatim: an unreadable timestamp is still a fact about
 * the account, and `Invalid Date` would hide it.
 */
export function formatTimestamp(value: string): string {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return value;
  }
  return parsed.toLocaleString();
}
