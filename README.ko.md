# Beryl

크래시 일관성 보장 단방향 추가 B-Tree 및 WAL 엔진 (Crash-Consistent Append-Only B-Tree & WAL Engine)

불변 Copy-on-Write (CoW) B-Tree와 결정론적 Write-Ahead Log (WAL)를 기반으로 구축된 임베디드 고성능 키-값 스토리지 엔진으로, Zig로 작성되었습니다.

[English Documentation](README.md)

## 아키텍처

- 완전 지속성 CoW B-Tree: 모든 페이지 변경은 새로운 버전의 노드를 생성합니다. 루트 포인터는 단조 증가하여 락(lock) 없이도 과거 스냅샷에 대한 읽기 일관성을 보장합니다.
- 결정론적 WAL 저널: 모든 변경 사항은 트리에 반영되기 전 길이 접두사(length-prefixed)와 CRC32 체크섬을 포함한 저널 레코드로 기록됩니다.
- 크래시 일관성 복구: 초기화 시 WAL을 스캔하여 레코드 무결성을 검증하고 커밋된 모든 트랜잭션을 재생하며, 미완료된 비정상 쓰기를 안전하게 폐기합니다.
- 예측 가능한 메모리 할당: 아레나 얼로케이터 및 하드웨어 가상 메모리 페이지 경계와 일치하는 고정 크기 4096바이트 페이지를 기반으로 동작합니다.
- C-ABI 동적 라이브러리: SQLite나 RocksDB 같은 무거운 외부 의존성 없이 C, Rust, Python, Go 환경에 직접 임베딩할 수 있는 표준 공유 라이브러리 심볼을 노출합니다.

## 데이터 모델 및 페이지 레이아웃

```
+-------------------------------------------------------------+
| Page Header (32 bytes)                                      |
| Magic (4B) | PageId (4B) | Generation (8B) | NumKeys (2B)   |
| IsLeaf (1B)| Reserved (9B)| CRC32 Checksum (4B)             |
+-------------------------------------------------------------+
| Ordered Key-Value Slots (up to 16 keys per 4KB node)        |
+-------------------------------------------------------------+
| Child Page Pointers (Internal nodes only: num_keys + 1)     |
+-------------------------------------------------------------+
```

## 빌드 및 테스트

```bash
# 단위 테스트 실행
zig build test

# 네이티브 바이너리 및 공유 라이브러리 빌드
zig build -Doptimize=ReleaseFast
```

## 라이선스

MIT License - Copyright (c) 2026 Jeong Hoon Kim
