//! Wire types for the review-avatar proxy. The fetch itself
//! (`harness-reviews::avatar::fetch_review_avatar`) stays in
//! `harness-reviews` since it makes a real outbound HTTP request; these two
//! DTOs are its whole wire shape.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsAvatarRequest {
    pub avatar_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsAvatarResponse {
    pub avatar_url: String,
    pub mime_type: String,
    pub content_base64: String,
    pub fetched_at: String,
}
