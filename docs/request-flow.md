API (:3000)
Orchestrator (:5008) 

请求

```
POST /process.Process/Start HTTP/1.1
host: localhost:5007
connection: keep-alive
User-Agent: e2b-js-sdk/2.18.0
connect-protocol-version: 1
connect-timeout-ms: 60000
content-type: application/connect+json
keepalive-ping-interval: 50
e2b-sandbox-id: ionfec0uaozpu5jacvfkz
e2b-sandbox-port: 49983
X-Access-Token: 541bacf5b7716eb610b9cc40cd9caf3865115081fc7c8d8e9ff4a8bb758983d8
accept: */*
accept-language: *
sec-fetch-mode: cors
accept-encoding: gzip, deflate
content-length: 96
```
```json
{
  "process": {
    "cmd": "/bin/bash",
    "args": [
      "-l",
      "-c",
      "echo \"Hello from E2B!\""
    ]
  },
  "stdin": false
}
```

响应:

```
HTTP/1.1 200 OK
Connect-Accept-Encoding: gzip
Content-Type: application/connect+json
Date: Wed, 08 Apr 2026 02:45:16 GMT
Vary: Origin
Transfer-Encoding: chunked
```
```json
{
  "event": {
    "start": {
      "pid": 405
    }
  }
}
{
  "event": {
    "data": {
      "stdout": "SGVsbG8gZnJvbSBFMkIhCg=="
    }
  }
}
{
  "event": {
    "end": {
      "exited": true,
      "status": "exit status 0"
    }
  }
}
{}
```

```
POST /sandboxes HTTP/1.1
host: localhost:3000
connection: keep-alive
Content-Type: application/json
browser: unknown
lang: js
lang_version: 22.19.0
package_version: 2.18.0
publisher: e2b
sdk_runtime: node
system: Linux
X-API-KEY: e2b_53ae1fed82754c17ad8077fbc8bcdd90
User-Agent: e2b-js-sdk/2.18.0
accept: */*
accept-language: *
sec-fetch-mode: cors
accept-encoding: gzip, deflate
content-length: 96

{
  "templateID": "base",
  "timeout": 300,
  "secure": true,
  "allow_internet_access": true,
  "autoPause": false
}


HTTP/1.1 201 Created
Content-Type: application/json; charset=utf-8
Date: Wed, 08 Apr 2026 04:31:25 GMT
Content-Length: 257

{
  "alias": "base",
  "clientID": "6532622b",
  "domain": null,
  "envdAccessToken": "d6c6924e864a2809cfa4eb3e1b66724024e03067b743f79d92603fe92a128c3d",
  "envdVersion": "0.5.8",
  "sandboxID": "ikpda5wr83e4pav42bqw5",
  "templateID": "4u5f5e393rle2b3x70m1",
  "trafficAccessToken": null
}

DELETE /sandboxes/ikpda5wr83e4pav42bqw5 HTTP/1.1
host: localhost:3000
connection: keep-alive
browser: unknown
lang: js
lang_version: 22.19.0
package_version: 2.18.0
publisher: e2b
sdk_runtime: node
system: Linux
X-API-KEY: e2b_53ae1fed82754c17ad8077fbc8bcdd90
User-Agent: e2b-js-sdk/2.18.0
accept: */*
accept-language: *
sec-fetch-mode: cors
accept-encoding: gzip, deflate


HTTP/1.1 204 No Content
Date: Wed, 08 Apr 2026 04:31:26 GMT

```
