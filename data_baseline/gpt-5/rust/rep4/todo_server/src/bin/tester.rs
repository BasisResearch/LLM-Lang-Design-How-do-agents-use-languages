use std::{process::{Command, Stdio}, thread, time::Duration};

use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
struct User { id: u64, username: String }

#[derive(Debug, Deserialize)]
struct Todo { id: u64, title: String, description: String, completed: bool, created_at: String, updated_at: String }

#[derive(Debug, Deserialize)]
struct ErrorResp { error: String }

#[tokio::main]
async fn main() {
    let port: u16 = 8123;

    // Build server first to ensure binary exists
    let status = Command::new("cargo")
        .args(["build", "--release"])
        .status()
        .expect("failed to build server");
    assert!(status.success(), "cargo build failed");

    // Start server
    let mut child = Command::new("./target/release/todo_server")
        .arg("--port").arg(port.to_string())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("failed to start server");

    // wait a bit
    thread::sleep(Duration::from_millis(500));

    let base = format!("http://127.0.0.1:{}", port);

    // Clients with cookie stores
    let client1 = Client::builder().cookie_store(true).build().unwrap();
    let client2 = Client::builder().cookie_store(true).build().unwrap();
    let anon = Client::new();

    // 1) Register alice
    let resp = client1.post(format!("{}/register", base))
        .json(&serde_json::json!({"username":"alice_1","password":"supersecret"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let u: User = resp.json().await.unwrap();
    assert_eq!(u.username, "alice_1");

    // Duplicate username
    let resp = client1.post(format!("{}/register", base))
        .json(&serde_json::json!({"username":"alice_1","password":"anotherpass"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);

    // Invalid username
    let resp = client1.post(format!("{}/register", base))
        .json(&serde_json::json!({"username":"a!","password":"supersecret"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Short password
    let resp = client1.post(format!("{}/register", base))
        .json(&serde_json::json!({"username":"bob_1","password":"short"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // 2) Login bad
    let resp = client1.post(format!("{}/login", base))
        .json(&serde_json::json!({"username":"alice_1","password":"wrongpass"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // 3) Login good
    let resp = client1.post(format!("{}/login", base))
        .json(&serde_json::json!({"username":"alice_1","password":"supersecret"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let _u: User = resp.json().await.unwrap();

    // 4) /me
    let resp = client1.get(format!("{}/me", base)).send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // 5) todos list empty
    let resp = client1.get(format!("{}/todos", base)).send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let arr: Vec<serde_json::Value> = resp.json().await.unwrap();
    assert!(arr.is_empty());

    // 6) create todo without title -> 400
    let resp = client1.post(format!("{}/todos", base))
        .json(&serde_json::json!({"description":"desc only"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // 7) create todo ok
    let resp = client1.post(format!("{}/todos", base))
        .json(&serde_json::json!({"title":"Task 1","description":"Do it"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let t: Todo = resp.json().await.unwrap();
    let id1 = t.id;

    // 8) get todo
    let resp = client1.get(format!("{}/todos/{}", base, id1)).send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // 9) update todo partial
    let resp = client1.put(format!("{}/todos/{}", base, id1))
        .json(&serde_json::json!({"completed":true}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let t2: Todo = resp.json().await.unwrap();
    assert!(t2.completed);

    // 10) update with empty title -> 400
    let resp = client1.put(format!("{}/todos/{}", base, id1))
        .json(&serde_json::json!({"title":""}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // 11) list todos non-empty
    let resp = client1.get(format!("{}/todos", base)).send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // 12) unauthorized /me without cookie
    let resp = anon.get(format!("{}/me", base)).send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // 13) second user creates todo, first user's todo should be hidden
    let resp = client2.post(format!("{}/register", base))
        .json(&serde_json::json!({"username":"charlie_1","password":"sufficient"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let resp = client2.post(format!("{}/login", base))
        .json(&serde_json::json!({"username":"charlie_1","password":"sufficient"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let resp = client2.get(format!("{}/todos/{}", base, id1)).send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    // 14) logout
    let resp = client1.post(format!("{}/logout", base)).send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let resp = client1.get(format!("{}/me", base)).send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // 15) password change
    // Need to login again to change password
    let resp = client1.post(format!("{}/login", base))
        .json(&serde_json::json!({"username":"alice_1","password":"supersecret"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let resp = client1.put(format!("{}/password", base))
        .json(&serde_json::json!({"old_password":"wrong","new_password":"newpassword"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    let resp = client1.put(format!("{}/password", base))
        .json(&serde_json::json!({"old_password":"supersecret","new_password":"short"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let resp = client1.put(format!("{}/password", base))
        .json(&serde_json::json!({"old_password":"supersecret","new_password":"newpassword"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // 16) verify old password fails, new works
    let resp = client1.post(format!("{}/login", base))
        .json(&serde_json::json!({"username":"alice_1","password":"supersecret"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    let resp = client1.post(format!("{}/login", base))
        .json(&serde_json::json!({"username":"alice_1","password":"newpassword"}))
        .send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // 17) delete todo
    // ensure logged in
    let _ = client1.post(format!("{}/login", base))
        .json(&serde_json::json!({"username":"alice_1","password":"newpassword"}))
        .send().await.unwrap();
    let resp = client1.delete(format!("{}/todos/{}", base, id1)).send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    let body = resp.bytes().await.unwrap();
    assert!(body.is_empty());

    // 18) get after delete -> 404
    let resp = client1.get(format!("{}/todos/{}", base, id1)).send().await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    // Cleanup
    let _ = child.kill();
    let _ = child.wait();

    println!("All tests passed");
}
