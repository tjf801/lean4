/-
Copyright (c) 2023 Amazon.com, Inc. or its affiliates. All Rights Reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
prelude
import Lean.PrettyPrinter
import Lean.Meta.Basic
import Lean.Meta.Instances

namespace Lean.Meta

private def collectAboveThreshold (counters : PHashMap Name Nat) (threshold : Nat) (p : Name → Bool) : Array (Name × Nat) := Id.run do
  let mut r := #[]
  for (declName, counter) in counters do
    if counter > threshold then
    if p declName then
      r := r.push (declName, counter)
  return r.qsort fun (d₁, c₁) (d₂, c₂) => if c₁ == c₂ then d₁.lt d₂ else c₁ > c₂

structure DiagSummary where
  data  : Array MessageData := #[]
  max   : Nat := 0
  deriving Inhabited

def DiagSummary.isEmpty (s : DiagSummary) : Bool :=
  s.data.isEmpty

def mkDiagSummary (counters : PHashMap Name Nat) (threshold : Nat) (p : Name → Bool := fun _ => true) : MetaM DiagSummary := do
  let entries := collectAboveThreshold counters threshold p
  if entries.isEmpty then
    return {}
  else
    let mut data := #[]
    for (declName, counter) in entries do
      data := data.push m!"{if data.isEmpty then "  " else "\n"}{MessageData.ofConst (← mkConstWithLevelParams declName)} ↦ {counter}"
    return { data, max := entries[0]!.2 }

def mkDiagSummaryForUnfolded (instances := false) : MetaM DiagSummary := do
  let threshold := diagnostics.threshold.get (← getOptions)
  let env ← getEnv
  mkDiagSummary (← get).diag.unfoldCounter threshold fun declName =>
    getReducibilityStatusCore env declName matches .semireducible
    && isInstanceCore env declName == instances

def mkDiagSummaryForUnfoldedReducible : MetaM DiagSummary := do
  let threshold := diagnostics.threshold.get (← getOptions)
  let env ← getEnv
  mkDiagSummary (← get).diag.unfoldCounter threshold fun declName =>
    getReducibilityStatusCore env declName matches .reducible

def mkDiagSummaryForUsedInstances : MetaM DiagSummary := do
  let threshold := diagnostics.threshold.get (← getOptions)
  mkDiagSummary (← get).diag.heuristicCounter threshold

def appendSection (m : MessageData) (cls : Name) (header : String) (s : DiagSummary) : MessageData :=
  if s.isEmpty then
    m
  else
    let header := s!"{header} (max: {s.max}, num: {s.data.size}):"
    m ++ .trace { cls } header s.data

def reportDiag : MetaM Unit := do
  if (← isDiagnosticsEnabled) then
    let threshold := diagnostics.threshold.get (← getOptions)
    let unfoldDefault ← mkDiagSummaryForUnfolded
    let unfoldInstance ← mkDiagSummaryForUnfolded (instances := true)
    let unfoldReducible ← mkDiagSummaryForUnfoldedReducible
    let heu ← mkDiagSummary (← get).diag.heuristicCounter threshold
    let inst ← mkDiagSummaryForUsedInstances
    unless unfoldDefault.isEmpty && unfoldInstance.isEmpty && unfoldReducible.isEmpty && heu.isEmpty && inst.isEmpty do
      let m := MessageData.nil
      let m := appendSection m `reduction "unfolded declarations" unfoldDefault
      let m := appendSection m `reduction "unfolded instances" unfoldInstance
      let m := appendSection m `reduction "unfolded reducible declarations" unfoldReducible
      let m := appendSection m `type_class "used instances" inst
      let m := appendSection m `def_eq "heuristic for solving `f a =?= f b`" heu
      let m := m ++ "use `set_option diagnostics.threshold <num>` to control threshold for reporting counters"
      logInfo m

end Lean.Meta
