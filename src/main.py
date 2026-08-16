from fastapi import FastAPI, Response, status


app = FastAPI(title="Speedsolve API")


@app.get("/health", status_code=status.HTTP_200_OK, response_class=Response)
async def health() -> Response:
    return Response(status_code=status.HTTP_200_OK)
