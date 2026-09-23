/-
  The policy boundary for Downdraft's reader position.

  PDFKit and iCloud are intentionally not modelled here: both are asynchronous
  sources of events.  This reducer determines which events are authoritative
  and which effects the Swift adapters are allowed to perform.
-/
namespace DowndraftReaderState

abbrev Page := Nat

structure Revision where
  page : Page
  sequence : Nat
  device : String
deriving DecidableEq, Repr

structure State where
  confirmedPage : Page
  localPage : Page
  linked : Bool
  startupProtected : Bool
  pendingShared : Option Revision
  handledShared : Option Revision
  history : List Page
deriving DecidableEq, Repr

inductive Event where
  | initialRestoreConfirmed (page : Page)
  | startupProtectionExpired
  | pdfReportedPage (page : Page)
  | readerMoved (page : Page)
  | sharedArrived (revision : Revision)
  | acceptShared
  | keepLocal
deriving DecidableEq, Repr

inductive Effect where
  | showPage (page : Page)
  | saveLocal (page : Page)
  | saveShared (page : Page)
  | showConflict (revision : Revision)
  | addHistory (source destination : Page)
deriving DecidableEq, Repr

def withPage (state : State) (page : Page) : State :=
  { state with confirmedPage := page, localPage := page }

def transition (state : State) (event : Event) : State × List Effect :=
  match event with
  | .initialRestoreConfirmed page =>
      ({ state with
          confirmedPage := page
          localPage := page
          startupProtected := true
          pendingShared := none }, [])
  | .startupProtectionExpired => ({ state with startupProtected := false }, [])
  | .pdfReportedPage _ =>
      -- Raw PDFKit callbacks are observations, never reader decisions.
      (state, [])
  | .readerMoved page =>
      let next := withPage state page
      if state.linked then
        (next, [.saveLocal page, .saveShared page])
      else
        (next, [.saveLocal page])
  | .sharedArrived revision =>
      if !state.linked || state.handledShared == some revision then
        (state, [])
      else if state.localPage == revision.page then
        ({ state with handledShared := some revision }, [])
      else
        ({ state with pendingShared := some revision }, [.showConflict revision])
  | .acceptShared =>
      match state.pendingShared with
      | none => (state, [])
      | some revision =>
          let next := { withPage state revision.page with
            pendingShared := none
            handledShared := some revision }
          if state.localPage == revision.page then
            (next, [.saveLocal revision.page])
          else
            ({ next with history := state.localPage :: state.history },
              [.addHistory state.localPage revision.page, .showPage revision.page,
                .saveLocal revision.page])
  | .keepLocal =>
      match state.pendingShared with
      | none => (state, [])
      | some revision =>
          ({ state with pendingShared := none, handledShared := some revision }, [])

def initial (page : Page := 0) : State := {
  confirmedPage := page
  localPage := page
  linked := true
  startupProtected := false
  pendingShared := none
  handledShared := none
  history := []
}

theorem raw_pdf_report_never_writes (state : State) (page : Page) :
    (transition state (.pdfReportedPage page)).2 = [] := by
  rfl

theorem raw_pdf_report_never_changes_state (state : State) (page : Page) :
    (transition state (.pdfReportedPage page)).1 = state := by
  rfl

theorem startup_restore_emits_no_write (state : State) (page : Page) :
    (transition state (.initialRestoreConfirmed page)).2 = [] := by
  rfl

theorem shared_conflict_does_not_move_reader
    (state : State) (revision : Revision)
    (hLinked : state.linked = true)
    (hUnhandled : state.handledShared ≠ some revision)
    (hDifferent : state.localPage ≠ revision.page) :
    (transition state (.sharedArrived revision)).1.confirmedPage = state.confirmedPage := by
  simp [transition, hLinked, hUnhandled, hDifferent]

theorem keep_local_does_not_move_reader (state : State) (revision : Revision) :
    (transition { state with pendingShared := some revision } .keepLocal).1.confirmedPage
      = state.confirmedPage := by
  rfl

theorem linked_reader_move_writes_shared (state : State) (page : Page)
    (hLinked : state.linked = true) :
    (transition state (.readerMoved page)).2 = [.saveLocal page, .saveShared page] := by
  simp [transition, hLinked]

theorem detached_reader_move_never_writes_shared (state : State) (page : Page)
    (hLinked : state.linked = false) :
    (transition state (.readerMoved page)).2 = [.saveLocal page] := by
  simp [transition, hLinked]

theorem accepted_shared_position_adds_history_when_different
    (state : State) (revision : Revision)
    (hDifferent : state.localPage ≠ revision.page) :
    (transition { state with pendingShared := some revision } .acceptShared).2
      = [.addHistory state.localPage revision.page, .showPage revision.page,
          .saveLocal revision.page] := by
  simp [transition, hDifferent]

end DowndraftReaderState
