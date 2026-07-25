/** One person who has signed in to the panel at least once. */
export interface PanelAccount {
  id: string;
  provider: string;
  subject_id: string;
  login: string;
  display_name: string;
  avatar_url: string | null;
  first_seen_at: string;
  last_seen_at: string;
}

/** The signed-in person, plus what the panel lets them see. */
export interface PanelViewer {
  account: PanelAccount;
  is_owner: boolean;
}

/** Error envelope every panel route uses for a non-2xx response. */
export interface PanelErrorBody {
  error: {
    code: string;
    message: string;
  };
}
