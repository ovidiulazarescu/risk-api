from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="Risk Scoring API")


class ScoreRequest(BaseModel):
    credit_utilization: float   # 0.0-1.0
    payment_history_score: int  # 0-100
    debt_to_income: float       # 0.0-1.0


class ScoreResponse(BaseModel):
    score: int
    risk_band: str


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/score", response_model=ScoreResponse)
def score(req: ScoreRequest):
    raw = (
        (1 - req.credit_utilization) * 400
        + req.payment_history_score * 3
        - req.debt_to_income * 200
    )
    value = max(300, min(850, int(raw)))
    band = "low" if value >= 700 else "medium" if value >= 580 else "high"
    return ScoreResponse(score=value, risk_band=band)
