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
  /** Whether the owner has allowed this account to generate pairing links. */
  can_pair: boolean;
}

/** A link the daemon minted, shown once and never stored. */
export interface PairLink {
  pairing_id: string;
  role: string;
  scopes: string[];
  expires_at: string;
  pairing_url: string;
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
