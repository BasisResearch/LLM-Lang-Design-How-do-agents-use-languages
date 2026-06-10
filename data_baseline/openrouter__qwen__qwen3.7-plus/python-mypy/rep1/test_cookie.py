from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse

app = FastAPI()

@app.post("/login")
async def login(response: Response):
    resp = JSONResponse(content={"message": "ok"})
    resp.set_cookie(key="session_id", value="test_token", httponly=True, path="/")
    return resp