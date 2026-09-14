FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 5000

ENV APP_VERSION=v1
ENV DELAY_MS=50
ENV ERROR_RATE=0.01

CMD ["python", "app.py"]
