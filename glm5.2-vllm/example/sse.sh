# 3) 如果想看流式输出（SSE）
curl -N http://192.168.0.4:7000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "glm-52",
    "messages": [
      {"role": "user", "content": "请用三句话介绍上海。"}
    ],
    "stream": true,
    "max_tokens": 128
  }'
