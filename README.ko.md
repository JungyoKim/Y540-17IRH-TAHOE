# Y540-17IRH-TAHOE (한국어 요약)

**Lenovo Legion Y540-17IRH**(i7-9750HF, GTX 1660 Ti)에 macOS 26.7.1 Tahoe를 설치하는 배포판이에요. NVIDIA 그래픽
가속(Metal 3), 내장 120 Hz 화면, HDMI 외장 모니터, 잠자기, 소리, Wi-Fi, 블루투스, AirDrop까지 동작해요.

그래픽 드라이버는 [NullMoth 1.13.0](https://github.com/nullmoth/nvidia-macos-driver) 위에 이 노트북에 맞춰 고친 빌드를
얹은 것이에요(잠자기와 깨우기, HDMI 핫플러그, 덮개 닫고 외장 모니터만 쓰기, 화면 출력 타이밍, Metal 플러그인 수정).
BCM94352Z 카드의 블루투스 광고와 AirDrop은 작은 패치 두 개로 살렸어요.

설치 방법은 [AGENTS.md](AGENTS.md)에 단계별로 있어요(영문, 다른 에이전트가 그대로 따라 할 수 있게 썼어요). 순서는 이래요.

1. BIOS에서 Secure Boot 끄기(BIOS 다운그레이드는 절대 금지)
2. macOS 26.7.1 설치 USB 만들고 이 저장소의 EFI 넣기(설치용 config, 맥 시리얼 생성)
3. SSD에 macOS 설치, 설정 지원이 마지막 단계에서 멈추면 복구 모드에서 `install/recovery-setup.sh` 실행
4. `install/fetch.sh`로 재료 받기(약 3.2 GB, 모두 SHA-256 검사)
5. `install/y540-install.sh` 1, 2, 3, 4단계를 차례로 실행하고 단계마다 재부팅
6. `install/verify.sh`로 확인(0 FAIL이면 끝)

꼭 지킬 것:

- macOS 26.7.1(25G241)에서만 동작해요. **macOS 업데이트를 설치하면 안 돼요.** 시스템 볼륨 패치(소리, Wi-Fi 등)가 지워져요.
- Samsung PM981 SSD는 macOS에서 동작하지 않아요. WD SN750으로 시험했어요.
- AirDrop은 BCM94352Z(DW1560) 카드가 필요하고, 설치 뒤 AirPlay 수신 모드를 꺼야 해요(블루투스 광고 슬롯이 하나뿐).
- macOS 밝기 슬라이더는 동작하지 않아요. Fn 밝기 키는 동작해요.

라이선스는 NullMoth와 같은 PolyForm Noncommercial 1.0.0이에요(무료, 상업적 사용 금지).

