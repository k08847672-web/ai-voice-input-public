# Third-party notices

本项目当前没有复制 KeyVox 或 SayIt 的源码、品牌或视觉资产。macOS 客户端只使用 Apple 系统
框架，业务 Swift 源码与 AppIcon 均为本项目原创。

以下工具或包通过包管理器使用。版本以 `server/requirements.lock`、
`server/requirements-dev.lock` 和 CI 配置为准；各项目的完整许可证文本以其发布包为准。

| Component | Purpose | Version | License | Distribution note |
|---|---|---:|---|---|
| FastAPI | ASGI API/WebSocket framework | 0.141.1 | MIT | Preserve license/copyright when redistributed |
| Starlette | ASGI and WebSocket runtime | 1.6.0 | BSD-3-Clause | Preserve notice and disclaimer |
| Pydantic / pydantic-core | Protocol validation | 2.13.4 / 2.46.4 | MIT | Preserve license/copyright |
| HTTPX / HTTPCore | Optional upstream HTTP ASR adapter | 0.28.1 / 1.0.9 | BSD-3-Clause | Preserve notice and disclaimer |
| Uvicorn | ASGI process | 0.52.3 | BSD-3-Clause | Preserve notice and disclaimer |
| AnyIO | Async runtime abstraction | 4.14.2 | MIT | Preserve license/copyright |
| certifi | TLS CA bundle metadata/runtime dependency | 2026.7.22 | MPL-2.0 | File-level copyleft; do not remove notices |
| XcodeGen | Development-time Xcode project generator | 2.42.0, archive SHA-256 pinned | MIT | Not shipped inside the application |
| OkHttp | Android WebSocket transport | 4.12.0 | Apache-2.0 | Preserve license and NOTICE when redistributing |
| Okio | OkHttp byte transport dependency | 3.6.0 | Apache-2.0 | Preserve license and NOTICE when redistributing |
| Kotlin standard library | OkHttp/Okio runtime dependency | 1.9.10 | Apache-2.0 | Preserve license notice when redistributing |
| Gradle wrapper / Android Gradle Plugin | Reproducible Android build | 8.13 / 8.13.2 | Apache-2.0 | Wrapper files are included; build plugin is development-only |
| GitHub Actions checkout/setup-python | CI actions | v4.4.0/v5.6.0 commits pinned | MIT | CI-only; follow upstream notices |
| Python base image | Reference server container runtime | 3.12.14 slim Bookworm, multi-arch digest pinned | PSF and Debian package licenses | Retain image/package notices and publish corresponding notices as required |

其他传递依赖包括 `annotated-doc`、`annotated-types`、`click`、`h11`、`httptools`、`idna`、
`python-dotenv`、`PyYAML`、`typing-inspection`、`typing_extensions`、`uvloop`、`watchfiles` 和
`websockets`。发布容器前必须使用镜像 SBOM/许可证扫描核对其当时版本与义务；不能把本文件当作
自动生成的完整 SBOM。

开发依赖 `pytest`、`pytest-cov`、`coverage`、`ruff`、`mypy`、`httpx2` 及其传递依赖不进入生产镜像。

Upstream references:

- <https://fastapi.tiangolo.com/>
- <https://www.starlette.io/>
- <https://docs.pydantic.dev/>
- <https://www.python-httpx.org/>
- <https://www.uvicorn.org/>
- <https://github.com/yonaskolb/XcodeGen>
