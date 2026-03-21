/// HTTP method for API requests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
    Put,
    Delete,
}

/// HTTP response from a block operation.
#[derive(Debug)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
}
