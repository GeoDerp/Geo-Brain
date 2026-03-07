#!/usr/bin/env python3
import sys
import json
import requests
import os

# Configuration (Use env variables from .env if possible)
DOMAIN = os.getenv("DOMAIN", "example.local")
LLM_URL = f"http://{DOMAIN}:8084/v1/chat/completions"

def analyze_output(source_name, content):
    print(f">>> Sending {source_name} data to RamaLama for evaluation...")
    
    prompt = f"""
    You are a Senior Security Analyst. Evaluate the following JSON/Log data from {source_name}.
    Summarize the key risks and prioritize the top 3 actionable items for a human operator.
    Be concise and professional.

    DATA:
    {content}
    """

    payload = {
        "model": "phi3:mini",
        "messages": [
            {"role": "system", "content": "You are a concise security analysis assistant."},
            {"role": "user", "content": prompt}
        ],
        "temperature": 0.2
    }

    try:
        response = requests.post(LLM_URL, json=payload, timeout=60)
        response.raise_for_status()
        result = response.json()
        print("\n--- LLM EVALUATION ---")
        print(result['choices'][0]['message']['content'])
        print("----------------------\n")
    except Exception as e:
        print(f"Error communicating with RamaLama: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: ./analyze_security.py [source_name] [file_path]")
        sys.exit(1)

    source = sys.argv[1]
    file_path = sys.argv[2]

    if not os.path.exists(file_path):
        print(f"File not found: {file_path}")
        sys.exit(1)

    with open(file_path, 'r') as f:
        data = f.read()
    
    analyze_output(source, data)
