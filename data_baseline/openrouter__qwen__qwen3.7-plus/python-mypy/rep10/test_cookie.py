from fastapi import FastAPI, Response

app = FastAPI()

@app.get("/")
def root(response: Response):
    response.set_cookie(key="session_id", value="test123", httponly=True, path="/")
    return {"message": "hello"}
