#!/bin/sh
# Hermetic stand-in for the `claude` CLI (--output-format stream-json). Tests point
# QUORUM_CLAUDE_BIN here. Set QUORUM_FAKE_SLEEP=1 to hang after init (abort/kill test).
printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-2222-4333-8444-555555555555","model":"claude-opus-4-20250101"}'
if [ -n "$QUORUM_FAKE_SLEEP" ]; then exec sleep 30; fi
cat <<'EOF'
{"type":"stream_event","session_id":"11111111-2222-4333-8444-555555555555","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Researching fusion. "}}}
{"type":"assistant","session_id":"11111111-2222-4333-8444-555555555555","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"nuclear fusion 2026"}}],"usage":{"input_tokens":1200,"output_tokens":80,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","session_id":"11111111-2222-4333-8444-555555555555","message":{"content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":1500,"output_tokens":300,"cache_read_input_tokens":200,"cache_creation_input_tokens":0}}}
{"type":"result","subtype":"success","session_id":"11111111-2222-4333-8444-555555555555","total_cost_usd":0.0123,"result":"Fusion crossed scientific breakeven at NIF.\n\n## Sources\n- [LLNL](https://www.llnl.gov/news/ignition)\n\n```json\n{\"headline\":\"Fusion advances\",\"status\":\"complete\",\"sourcesConsulted\":1,\"findings\":[{\"claim\":\"NIF achieved ignition\",\"sources\":[\"https://www.llnl.gov/news/ignition\"],\"confidence\":\"high\"}]}\n```","usage":{"input_tokens":2700,"output_tokens":380,"cache_read_input_tokens":200,"cache_creation_input_tokens":0}}
EOF
