use axum::{extract::{FromRequest, Request}, http::StatusCode, response::IntoResponse, Json};
use serde::de::DeserializeOwned;

use crate::ErrorBody;

pub struct StrictJson<T>(pub T);

#[axum::async_trait]
impl<S, T> FromRequest<S> for StrictJson<T>
where
    S: Send + Sync,
    T: DeserializeOwned,
{
    type Rejection = axum::response::Response;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        match Json::<T>::from_request(req, state).await {
            Ok(Json(value)) => Ok(StrictJson(value)),
            Err(rej) => {
                let msg = rej.body_text();
                let resp = (StatusCode::BAD_REQUEST, Json(ErrorBody { error: msg })).into_response();
                Err(resp)
            }
        }
    }
}
