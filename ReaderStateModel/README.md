# Downdraft Reader State Model

`ReaderStateModel.lean` describes the policy that sits between asynchronous
sources (PDFKit and iCloud) and reader effects (moving the visible page,
persisting local progress, writing shared progress, history, and conflict UI).

Run its proofs with:

```sh
lake env lean ReaderStateModel.lean
```

The matching Swift reducer is
[`Downdraft/ReaderPositionStateMachine.swift`](../Downdraft/ReaderPositionStateMachine.swift).
Its scenario tests are
[`DowndraftTests/ReaderPositionStateMachineTests.swift`](../DowndraftTests/ReaderPositionStateMachineTests.swift).

The model deliberately treats a raw `pdfReportedPage` as an observation with
no effects. The PDFKit adapter must first establish that it follows reader
motion or an explicit command before emitting `readerMoved` to the policy.

The current proved invariants cover:

- Raw PDFKit reports neither move the confirmed cursor nor save progress.
- A startup restore creates no write effect.
- A new shared position that differs from the local position leaves the reader
  in place and produces only a conflict effect.
- Keeping the local position leaves the confirmed cursor unchanged.
- Linked reader motion writes local and shared progress; detached motion writes
  only local progress.
- Accepting a different shared position creates exactly one history entry,
  shows that page, and saves the local cursor.
