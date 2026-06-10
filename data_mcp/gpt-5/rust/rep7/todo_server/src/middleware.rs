use axum::{body::Body, http::{HeaderValue, StatusCode, header, Method, Request}, middleware::Next, response::Response};

// Ensure all JSON responses include application/json content type except DELETE 204.
pub async fn enforce_json_content_type(req: Request<Body>, next: Next) -> Response {
    let method_is_delete = req.method() == Method::DELETE;
    let mut response = next.run(req).await;
    let status = response.status();
    if method_is_delete && status == StatusCode::NO_CONTENT {
        return response;
    }
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    response
}
