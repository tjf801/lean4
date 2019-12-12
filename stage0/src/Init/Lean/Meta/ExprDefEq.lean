/-
Copyright (c) 2019 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
prelude
import Init.Lean.ProjFns
import Init.Lean.Meta.WHNF
import Init.Lean.Meta.InferType
import Init.Lean.Meta.FunInfo
import Init.Lean.Meta.LevelDefEq
import Init.Lean.Meta.Check
import Init.Lean.Meta.Offset

namespace Lean
namespace Meta

/--
  Try to solve `a := (fun x => t) =?= b` by eta-expanding `b`.

  Remark: eta-reduction is not a good alternative even in a system without universe cumulativity like Lean.
  Example:
    ```
    (fun x : A => f ?m) =?= f
    ```
    The left-hand side of the constraint above it not eta-reduced because `?m` is a metavariable. -/
private def isDefEqEta (a b : Expr) : MetaM Bool :=
if a.isLambda && !b.isLambda then do
  bType ← inferType b;
  bType ← whnfUsingDefault bType;
  match bType with
  | Expr.forallE n d _ c =>
    let b' := Lean.mkLambda n c.binderInfo d (mkApp b (mkBVar 0));
    try $ isExprDefEqAux a b'
  | _ => pure false
else
  pure false

/--
  Return `true` if `e` is of the form `fun (x_1 ... x_n) => ?m x_1 ... x_n)`, and `?m` is unassigned.
  Remark: `n` may be 0. -/
def isEtaUnassignedMVar (e : Expr) : MetaM Bool :=
match e.etaExpanded? with
| some (Expr.mvar mvarId _) =>
  condM (isReadOnlyOrSyntheticExprMVar mvarId)
    (pure false)
    (condM (isExprMVarAssigned mvarId)
      (pure false)
      (pure true))
| _   => pure false


/-
  First pass for `isDefEqArgs`. We unify explicit arguments, *and* easy cases
  Here, we say a case is easy if it is of the form

       ?m =?= t
       or
       t  =?= ?m

  where `?m` is unassigned.

  These easy cases are not just an optimization. When
  `?m` is a function, by assigning it to t, we make sure
  a unification constraint (in the explicit part)
  ```
  ?m t =?= f s
  ```
  is not higher-order.

  We also handle the eta-expanded cases:
  ```
  fun x₁ ... xₙ => ?m x₁ ... xₙ =?= t
  t =?= fun x₁ ... xₙ => ?m x₁ ... xₙ

  This is important because type inference often produces
  eta-expanded terms, and without this extra case, we could
  introduce counter intuitive behavior.

  Pre: `paramInfo.size <= args₁.size = args₂.size`
-/
private partial def isDefEqArgsFirstPass
    (paramInfo : Array ParamInfo) (args₁ args₂ : Array Expr) : Nat → Array Nat → MetaM (Option (Array Nat))
| i, postponed =>
  if h : i < paramInfo.size then
    let info := paramInfo.get ⟨i, h⟩;
    let a₁ := args₁.get! i;
    let a₂ := args₂.get! i;
    if info.implicit || info.instImplicit then
      condM (isEtaUnassignedMVar a₁ <||> isEtaUnassignedMVar a₂)
        (condM (isExprDefEqAux a₁ a₂)
          (isDefEqArgsFirstPass (i+1) postponed)
          (pure none))
        (isDefEqArgsFirstPass (i+1) (postponed.push i))
    else
      condM (isExprDefEqAux a₁ a₂)
        (isDefEqArgsFirstPass (i+1) postponed)
        (pure none)
  else
    pure (some postponed)

private partial def isDefEqArgsAux (args₁ args₂ : Array Expr) (h : args₁.size = args₂.size) : Nat → MetaM Bool
| i =>
  if h₁ : i < args₁.size then
    let a₁ := args₁.get ⟨i, h₁⟩;
    let a₂ := args₂.get ⟨i, h ▸ h₁⟩;
    condM (isExprDefEqAux a₁ a₂)
      (isDefEqArgsAux (i+1))
      (pure false)
  else
    pure true

private def isDefEqArgs (f : Expr) (args₁ args₂ : Array Expr) : MetaM Bool :=
if h : args₁.size = args₂.size then do
  finfo ← getFunInfoNArgs f args₁.size;
  (some postponed) ← isDefEqArgsFirstPass finfo.paramInfo args₁ args₂ 0 #[] | pure false;
  (isDefEqArgsAux args₁ args₂ h finfo.paramInfo.size)
  <&&>
  (postponed.allM $ fun i => do
   /- Second pass: unify implicit arguments.
      In the second pass, we make sure we are unfolding at
      least non reducible definitions (default setting). -/
    let a₁   := args₁.get! i;
    let a₂   := args₂.get! i;
    let info := finfo.paramInfo.get! i;
    when info.instImplicit $ do {
      synthPending a₁;
      synthPending a₂;
      pure ()
    };
    usingAtLeastTransparency TransparencyMode.default $ isExprDefEqAux a₁ a₂)
else
  pure false

/--
  Check whether the types of the free variables at `fvars` are
  definitionally equal to the types at `ds₂`.

  Pre: `fvars.size == ds₂.size`

  This method also updates the set of local instances, and invokes
  the continuation `k` with the updated set.

  We can't use `withNewLocalInstances` because the `isDeq fvarType d₂`
  may use local instances. -/
@[specialize] partial def isDefEqBindingDomain (fvars : Array Expr) (ds₂ : Array Expr) : Nat → MetaM Bool → MetaM Bool
| i, k =>
  if h : i < fvars.size then do
    let fvar := fvars.get ⟨i, h⟩;
    fvarDecl ← getFVarLocalDecl fvar;
    let fvarType := fvarDecl.type;
    let d₂       := ds₂.get! i;
    condM (isExprDefEqAux fvarType d₂)
      (do c? ← isClass fvarType;
          match c? with
          | some className => withNewLocalInstance className fvar $ isDefEqBindingDomain (i+1) k
          | none           => isDefEqBindingDomain (i+1) k)
      (pure false)
  else
    k

/- Auxiliary function for `isDefEqBinding` for handling binders `forall/fun`.
   It accumulates the new free variables in `fvars`, and declare them at `lctx`.
   We use the domain types of `e₁` to create the new free variables.
   We store the domain types of `e₂` at `ds₂`. -/
private partial def isDefEqBindingAux : LocalContext → Array Expr → Expr → Expr → Array Expr → MetaM Bool
| lctx, fvars, e₁, e₂, ds₂ =>
  let process (n : Name) (d₁ d₂ b₁ b₂ : Expr) : MetaM Bool := do {
    let d₁    := d₁.instantiateRev fvars;
    let d₂    := d₂.instantiateRev fvars;
    fvarId    ← mkFreshId;
    let lctx  := lctx.mkLocalDecl fvarId n d₁;
    let fvars := fvars.push (mkFVar fvarId);
    isDefEqBindingAux lctx fvars b₁ b₂ (ds₂.push d₂)
  };
  match e₁, e₂ with
  | Expr.forallE n d₁ b₁ _, Expr.forallE _ d₂ b₂ _ => process n d₁ d₂ b₁ b₂
  | Expr.lam     n d₁ b₁ _, Expr.lam     _ d₂ b₂ _ => process n d₁ d₂ b₁ b₂
  | _,                      _                      =>
    adaptReader (fun (ctx : Context) => { lctx := lctx, .. ctx }) $
      isDefEqBindingDomain fvars ds₂ 0 $
        isExprDefEqAux (e₁.instantiateRev fvars) (e₂.instantiateRev fvars)

@[inline] private def isDefEqBinding (a b : Expr) : MetaM Bool := do
lctx ← getLCtx;
isDefEqBindingAux lctx #[] a b #[]

/-
  Each metavariable is declared in a particular local context.
  We use the notation `C |- ?m : t` to denote a metavariable `?m` that
  was declared at the local context `C` with type `t` (see `MetavarDecl`).
  We also use `?m@C` as a shorthand for `C |- ?m : t` where `t` is the type of `?m`.

  The following method process the unification constraint

       ?m@C a₁ ... aₙ =?= t

  We say the unification constraint is a pattern IFF

    1) `a₁ ... aₙ` are pairwise distinct free variables that are ​*not*​ let-variables.
    2) `a₁ ... aₙ` are not in `C`
    3) `t` only contains free variables in `C` and/or `{a₁, ..., aₙ}`
    4) For every metavariable `?m'@C'` occurring in `t`, `C'` is a subprefix of `C`
    5) `?m` does not occur in `t`

  Claim: we don't have to check free variable declarations. That is,
  if `t` contains a reference to `x : A := v`, we don't need to check `v`.
  Reason: The reference to `x` is a free variable, and it must be in `C` (by 1 and 3).
  If `x` is in `C`, then any metavariable occurring in `v` must have been defined in a strict subprefix of `C`.
  So, condition 4 and 5 are satisfied.

  If the conditions above have been satisfied, then the
  solution for the unification constrain is

    ?m := fun a₁ ... aₙ => t

  Now, we consider some workarounds/approximations.

 A1) Suppose `t` contains a reference to `x : A := v` and `x` is not in `C` (failed condition 3)
     (precise) solution: unfold `x` in `t`.

 A2) Suppose some `aᵢ` is in `C` (failed condition 2)
     (approximated) solution (when `config.foApprox` is set to true) :
     ignore condition and also use

        ?m := fun a₁ ... aₙ => t

   Here is an example where this approximation fails:
   Given `C` containing `a : nat`, consider the following two constraints
         ?m@C a =?= a
         ?m@C b =?= a

   If we use the approximation in the first constraint, we get
         ?m := fun x => x
   when we apply this solution to the second one we get a failure.

   IMPORTANT: When applying this approximation we need to make sure the
   abstracted term `fun a₁ ... aₙ => t` is type correct. The check
   can only be skipped in the pattern case described above. Consider
   the following example. Given the local context

      (α : Type) (a : α)

   we try to solve

     ?m α =?= @id α a

   If we use the approximation above we obtain:

     ?m := (fun α' => @id α' a)

   which is a type incorrect term. `a` has type `α` but it is expected to have
   type `α'`.

   The problem occurs because the right hand side contains a free variable
   `a` that depends on the free variable `α` being abstracted. Note that
   this dependency cannot occur in patterns.

   Here is another example in the same local context

      ?m_1 α =?= id ?m_2

   If we use the approximation above we obtain:

      ?m_1 := (fun α' => id (?m_2' α'))

   where `?m_2'` is a new metavariable, and `?m_2 := ?m_2 α`

   Now, suppose we assign `?m_2'`.

     ?m_2 := (fun α => @id α a)

   Then, we have

      ?m_1 := (fun α' => id (@id α' a))

   which is again type incorrect.

   We can address the issue on the first example by type checking
   the term after abstraction. This is not a significant performance
   bottleneck because this case doesn't happen very often in practice
   (262 times when compiling stdlib on Jan 2018). The second example
   is trickier, but it also occurs less frequently (8 times when compiling
   stdlib on Jan 2018, and all occurrences were at Init/Control when
   we define monads and auxiliary combinators for them).
   We considered three options for the addressing the issue on the second example:

    a) For each metavariable that may contain a free variable
       that depends on a term being abstracted, we create a fresh metavariable
       with a smaller local context. In the example above, when we perform
       the assignment

         ?m_1 := (fun α' => id (?m_2' α'))

    b) If we find a metavariable with this kind of dependency, we just
       fail and fallback to first-order unification.

    c) If we find a metavariable on the term after abstraction, we just
       fail and fallback to first-order unification.

   The first two options are incomparable, each one of them can solve
   problems where the other fails. The third one is weaker than the second,
   but we didn't find any example in the stdlib where the second option
   applies. The first and third options are also incomparable.

   So, we decide to use the third option since it is the simplest to implement,
   and all examples we have identified are in Init/Control.

 A3) `a₁ ... aₙ` are not pairwise distinct (failed condition 1).
   In Lean3, we would try to approximate this case using an approach similar to A2.
   However, this approximation complicates the code, and is never used in the
   Lean3 stdlib and mathlib.

 A4) `t` contains a metavariable `?m'@C'` where `C'` is not a subprefix of `C`.
   (approximated) solution: restrict the context of `?m'`
   If `?m'` is assigned, the workaround is precise, and we just unfold `?m'`.

 A5) If some `aᵢ` is not a free variable,
     then we use first-order unification (if `config.foApprox` is set to true)

       ?m a_1 ... a_i a_{i+1} ... a_{i+k} =?= f b_1 ... b_k

   reduces to

       ?M a_1 ... a_i =?= f
       a_{i+1}        =?= b_1
       ...
       a_{i+k}        =?= b_k


 A6) If (m =?= v) is of the form

        ?m a_1 ... a_n =?= ?m b_1 ... b_k

     then we use first-order unification (if `config.foApprox` is set to true)
-/

namespace CheckAssignment

structure Context :=
(lctx         : LocalContext)
(mvarId       : MVarId)
(mvarDecl     : MetavarDecl)
(fvars        : Array Expr)
(ctxApprox    : Bool)
(hasCtxLocals : Bool)

inductive Exception
| occursCheck
| useFOApprox
| outOfScopeFVar                     (fvarId : FVarId)
| readOnlyMVarWithBiggerLCtx         (mvarId : MVarId)
| mvarTypeNotWellFormedInSmallerLCtx (mvarId : MVarId)
| unknownExprMVar                    (mvarId : MVarId)

structure State :=
(mctx  : MetavarContext)
(ngen  : NameGenerator)
(cache : ExprStructMap Expr := {})

abbrev CheckAssignmentM := ReaderT Context (EStateM Exception State)

private def findCached (e : Expr) : CheckAssignmentM (Option Expr) := do
s ← get; pure $ s.cache.find e

private def cache (e r : Expr) : CheckAssignmentM Unit :=
modify $ fun s => { cache := s.cache.insert e r, .. s }

instance : MonadCache Expr Expr CheckAssignmentM :=
{ findCached := findCached, cache := cache }

@[inline] private def visit (f : Expr → CheckAssignmentM Expr) (e : Expr) : CheckAssignmentM Expr :=
if !e.hasExprMVar && !e.hasFVar then pure e else checkCache e f

@[specialize] def checkFVar (check : Expr → CheckAssignmentM Expr) (fvar : Expr) : CheckAssignmentM Expr := do
ctx ← read;
if ctx.mvarDecl.lctx.containsFVar fvar then pure fvar
else do
  let lctx := ctx.lctx;
  match lctx.findFVar fvar with
  | some (LocalDecl.ldecl _ _ _ _ v) => visit check v
  | _ =>
    if ctx.fvars.contains fvar then pure fvar
    else throw $ Exception.outOfScopeFVar fvar.fvarId!

@[inline] def getMCtx : CheckAssignmentM MetavarContext := do
s ← get; pure s.mctx

def mkAuxMVar (lctx : LocalContext) (localInsts : LocalInstances) (type : Expr) : CheckAssignmentM Expr := do
s ← get;
let mvarId := s.ngen.curr;
modify $ fun s => { ngen := s.ngen.next, mctx := s.mctx.addExprMVarDecl mvarId Name.anonymous lctx localInsts type, .. s };
pure (mkMVar mvarId)

@[specialize] def checkMVar (check : Expr → CheckAssignmentM Expr) (mvar : Expr) : CheckAssignmentM Expr := do
let mvarId := mvar.mvarId!;
ctx  ← read;
mctx ← getMCtx;
match mctx.getExprAssignment mvarId with
| some v => visit check v
| none   =>
  if mvarId == ctx.mvarId then throw Exception.occursCheck
  else match mctx.findDecl mvarId with
    | none          => throw $ Exception.unknownExprMVar mvarId
    | some mvarDecl =>
      if ctx.hasCtxLocals then throw $ Exception.useFOApprox -- we use option c) described at workaround A2
      else if mvarDecl.lctx.isSubPrefixOf ctx.mvarDecl.lctx then pure mvar
      else if mvarDecl.depth != mctx.depth || mvarDecl.synthetic then throw $ Exception.readOnlyMVarWithBiggerLCtx mvarId
      else if ctx.ctxApprox && ctx.mvarDecl.lctx.isSubPrefixOf mvarDecl.lctx then
        let mvarType := mvarDecl.type;
        if mctx.isWellFormed ctx.mvarDecl.lctx mvarType then do
          /- Create an auxiliary metavariable with a smaller context. -/
          newMVar ← mkAuxMVar ctx.mvarDecl.lctx ctx.mvarDecl.localInstances mvarType;
          modify $ fun s => { mctx := s.mctx.assignExpr mvarId newMVar, .. s };
          pure newMVar
        else
          throw $ Exception.mvarTypeNotWellFormedInSmallerLCtx mvarId
      else
        pure mvar

partial def check : Expr → CheckAssignmentM Expr
| e@(Expr.mdata _ b _)     => do b ← visit check b; pure $ e.updateMData! b
| e@(Expr.proj _ _ s _)    => do s ← visit check s; pure $ e.updateProj! s
| e@(Expr.app f a _)       => do f ← visit check f; a ← visit check a; pure $ e.updateApp! f a
| e@(Expr.lam _ d b _)     => do d ← visit check d; b ← visit check b; pure $ e.updateLambdaE! d b
| e@(Expr.forallE _ d b _) => do d ← visit check d; b ← visit check b; pure $ e.updateForallE! d b
| e@(Expr.letE _ t v b _)  => do t ← visit check t; v ← visit check v; b ← visit check b; pure $ e.updateLet! t v b
| e@(Expr.bvar _ _)        => pure e
| e@(Expr.sort _ _)        => pure e
| e@(Expr.const _ _ _)     => pure e
| e@(Expr.lit _ _)         => pure e
| e@(Expr.fvar _ _)        => visit (checkFVar check) e
| e@(Expr.mvar _ _)        => visit (checkMVar check) e
| Expr.localE _ _ _ _      => unreachable!

end CheckAssignment

private def checkAssignmentFailure (mvarId : MVarId) (fvars : Array Expr) (v : Expr) (ex : CheckAssignment.Exception) : MetaM (Option Expr) :=
match ex with
| CheckAssignment.Exception.occursCheck => do
  trace! `Meta.isDefEq.assign.occursCheck (mkMVar mvarId ++ fvars ++ " := " ++ v);
  pure none
| CheckAssignment.Exception.useFOApprox =>
  pure none
| CheckAssignment.Exception.outOfScopeFVar fvarId => do
  trace! `Meta.isDefEq.assign.outOfScopeFVar (mkFVar fvarId ++ " @ " ++ mkMVar mvarId ++ fvars ++ " := " ++ v);
  pure none
| CheckAssignment.Exception.readOnlyMVarWithBiggerLCtx nestedMVarId => do
  trace! `Meta.isDefEq.assign.readOnlyMVarWithBiggerLCtx (mkMVar nestedMVarId ++ " @ " ++ mkMVar mvarId ++ fvars ++ " := " ++ v);
  pure none
| CheckAssignment.Exception.mvarTypeNotWellFormedInSmallerLCtx nestedMVarId => do
  trace! `Meta.isDefEq.assign.mvarTypeNotWellFormedInSmallerLCtx (mkMVar nestedMVarId ++ " @ " ++ mkMVar mvarId ++ fvars ++ " := " ++ v);
  pure none
| CheckAssignment.Exception.unknownExprMVar mvarId =>
  -- This case can only happen if the MetaM API is being misused
  throwEx $ Exception.unknownExprMVar mvarId

namespace CheckAssignmentQuick

@[inline] private def visit (f : Expr → Bool) (e : Expr) : Bool :=
if !e.hasExprMVar && !e.hasFVar then true else f e

partial def check
    (hasCtxLocals ctxApprox : Bool)
    (mctx : MetavarContext) (lctx : LocalContext) (mvarDecl : MetavarDecl) (mvarId : MVarId) (fvars : Array Expr) : Expr → Bool
| e@(Expr.mdata _ b _)     => check b
| e@(Expr.proj _ _ s _)    => check s
| e@(Expr.app f a _)       => visit check f && visit check a
| e@(Expr.lam _ d b _)     => visit check d && visit check b
| e@(Expr.forallE _ d b _) => visit check d && visit check b
| e@(Expr.letE _ t v b _)  => visit check t && visit check v && visit check b
| e@(Expr.bvar _ _)        => true
| e@(Expr.sort _ _)        => true
| e@(Expr.const _ _ _)     => true
| e@(Expr.lit _ _)         => true
| e@(Expr.fvar fvarId _)   =>
  if mvarDecl.lctx.contains fvarId then true
  else match lctx.find fvarId with
    | some (LocalDecl.ldecl _ _ _ _ v) => false -- need expensive CheckAssignment.check
    | _ =>
      if fvars.any $ fun x => x.fvarId! == fvarId then true
      else false -- We could throw an exception here, but we would have to use ExceptM. So, we let CheckAssignment.check do it
| e@(Expr.mvar mvarId' _)        => do
  match mctx.getExprAssignment mvarId' with
  | some _ => false -- use CheckAssignment.check to instantiate
  | none   =>
    if mvarId' == mvarId then false -- occurs check failed, use CheckAssignment.check to throw exception
    else match mctx.findDecl mvarId' with
      | none           => false
      | some mvarDecl' =>
        if hasCtxLocals then false -- use CheckAssignment.check
        else if mvarDecl'.lctx.isSubPrefixOf mvarDecl.lctx then true
        else if mvarDecl'.depth != mctx.depth || mvarDecl'.synthetic then false  -- use CheckAssignment.check
        else if ctxApprox && mvarDecl.lctx.isSubPrefixOf mvarDecl'.lctx then false  -- use CheckAssignment.check
        else true
| Expr.localE _ _ _ _      => unreachable!

end CheckAssignmentQuick

/--
  Auxiliary function for handling constraints of the form `?m a₁ ... aₙ =?= v`.
  It will check whether we can perform the assignment
  ```
  ?m := fun fvars => t
  ```
  The result is `none` if the assignment can't be performed.
  The result is `some newV` where `newV` is a possibly updated `v`. This method may need
  to unfold let-declarations. -/
def checkAssignment (mvarId : MVarId) (fvars : Array Expr) (v : Expr) : MetaM (Option Expr) :=
fun ctx s => if !v.hasExprMVar && !v.hasFVar then EStateM.Result.ok (some v) s else
  let mvarDecl     := s.mctx.getDecl mvarId;
  let hasCtxLocals := fvars.any $ fun fvar => mvarDecl.lctx.containsFVar fvar;
  if CheckAssignmentQuick.check hasCtxLocals ctx.config.ctxApprox s.mctx ctx.lctx mvarDecl mvarId fvars v then
    EStateM.Result.ok (some v) s
  else
    let checkCtx : CheckAssignment.Context := {
      lctx         := ctx.lctx,
      mvarId       := mvarId,
      mvarDecl     := s.mctx.getDecl mvarId,
      fvars        := fvars,
      ctxApprox    := ctx.config.ctxApprox,
      hasCtxLocals := hasCtxLocals
    };
    match (CheckAssignment.check v checkCtx).run { mctx := s.mctx, ngen := s.ngen } with
    | EStateM.Result.ok e newS     => EStateM.Result.ok (some e) { mctx := newS.mctx, ngen := newS.ngen, .. s }
    | EStateM.Result.error ex newS => checkAssignmentFailure mvarId fvars v ex ctx { ngen := newS.ngen, .. s }

/-
  We try to unify arguments before we try to unify the functions.
  The motivation is the following: the universe constraints in
  the arguments propagate to the function. -/
private partial def isDefEqFOApprox (f₁ f₂ : Expr) (args₁ args₂ : Array Expr) : Nat → Nat → MetaM Bool
| i₁, i₂ =>
  if h : i₂ < args₂.size then
    let arg₁ := args₁.get! i₁;
    let arg₂ := args₂.get ⟨i₂, h⟩;
    condM (isExprDefEqAux arg₁ arg₂)
      (isDefEqFOApprox (i₁+1) (i₂+1))
      (pure false)
  else
    isExprDefEqAux f₁ f₂

private def processAssignmentFOApproxAux (mvar : Expr) (args : Array Expr) (v : Expr) : MetaM Bool :=
let vArgs := v.getAppArgs;
if vArgs.isEmpty then
  /- ?m a_1 ... a_k =?= t,  where t is not an application -/
  pure false
else if args.size > vArgs.size then
  /-
    ?m a_1 ... a_i a_{i+1} ... a_{i+k} =?= f b_1 ... b_k

    reduces to

    ?m a_1 ... a_i =?= f
    a_{i+1}        =?= b_1
    ...
    a_{i+k}        =?= b_k
  -/
  let f₁ := mkAppRange mvar 0 (args.size - vArgs.size) args;
  let i₁ := args.size - vArgs.size;
  isDefEqFOApprox f₁ v.getAppFn args vArgs i₁ 0
else if args.size < vArgs.size then
  /-
    ?m a_1 ... a_k =?= f b_1 ... b_i b_{i+1} ... b_{i+k}

    reduces to

    ?m  =?= f b_1 ... b_i
    a_1 =?= b_{i+1}
    ...
    a_k =?= b_{i+k}
  -/
  let vFn := mkAppRange v.getAppFn 0 (vArgs.size - args.size) vArgs;
  let i₂  := vArgs.size - args.size;
  isDefEqFOApprox mvar vFn args vArgs 0 i₂
else
  /-
    ?m a_1 ... a_k =?= f b_1 ... b_k

    reduces to

    ?m  =?= f
    a_1 =?= b_1
    ...
    a_k =?= b_k
  -/
  isDefEqFOApprox mvar v.getAppFn args vArgs 0 0

/-
  Auxiliary method for applying first-order unification. It is an approximation.
  Remark: this method is trying to solve the unification constraint:

      ?m a₁ ... aₙ =?= v

   It is uses processAssignmentFOApproxAux, if it fails, it tries to unfold `v`.

   We have added support for unfolding here because we want to be able to solve unification problems such as

      ?m Unit =?= ITactic

   where `ITactic` is defined as

   def ITactic := Tactic Unit
-/
private partial def processAssignmentFOApprox (mvar : Expr) (args : Array Expr) : Expr → MetaM Bool
| v => do
  trace! `Meta.isDefEq.foApprox (mvar ++ " " ++ args ++ " := " ++ v);
  condM (try $ processAssignmentFOApproxAux mvar args v)
    (pure true)
    (do v? ← unfoldDefinition v;
        match v? with
        | none   => pure false
        | some v => processAssignmentFOApprox v)

private partial def simpAssignmentArgAux : Expr → MetaM Expr
| Expr.mdata _ e _       => simpAssignmentArgAux e
| e@(Expr.fvar fvarId _) => do
  decl ← getLocalDecl fvarId;
  match decl.value? with
  | some value => simpAssignmentArgAux value
  | _          => pure e
| e => pure e

/- Auxiliary procedure for processing `?m a₁ ... aₙ =?= v`.
   We apply it to each `aᵢ`. It instantiates assigned metavariables if `aᵢ` is of the form `f[?n] b₁ ... bₘ`,
   and then removes metadata, and zeta-expand let-decls. -/
private def simpAssignmentArg (arg : Expr) : MetaM Expr := do
arg ← if arg.getAppFn.hasExprMVar then instantiateMVars arg else pure arg;
simpAssignmentArgAux arg

private partial def processAssignmentAux (mvar : Expr) (mvarDecl : MetavarDecl) (v : Expr) : Nat → Array Expr → MetaM Bool
| i, args =>
  if h : i < args.size then do
    cfg ← getConfig;
    let arg := args.get ⟨i, h⟩;
    arg ← simpAssignmentArg arg;
    let args := args.set ⟨i, h⟩ arg;
    let useFOApprox : Unit → MetaM Bool := fun _ =>
      if cfg.foApprox then
        processAssignmentFOApprox mvar args v
      else
        pure false;
    match arg with
    | Expr.fvar fvarId _ =>
      if args.anyRange 0 i (fun prevArg => prevArg == arg) then
        useFOApprox ()
      else if mvarDecl.lctx.contains fvarId && !cfg.quasiPatternApprox then
        useFOApprox ()
      else
        processAssignmentAux (i+1) args
    | _ =>
      useFOApprox ()
  else do
    cfg ← getConfig;
    v ← instantiateMVars v; -- enforce A4
    if cfg.foApprox && args.isEmpty && v.getAppFn == mvar then
      processAssignmentFOApprox mvar args v
    else do
      let useFOApprox : Unit → MetaM Bool := fun _ =>
        if cfg.foApprox then processAssignmentFOApprox mvar args v
        else pure false;
      let mvarId := mvar.mvarId!;
      v? ← checkAssignment mvarId args v;
      match v? with
      | none => useFOApprox ()
      | some v => do
        v ← mkLambda args v;
        let finalize : Unit → MetaM Bool := fun _ => traceCtx `Meta.isDefEq.assign.checkTypes $ do {
           -- must check whether types are definitionally equal or not, before assigning and returning true
           mvarType ← inferType mvar;
           vType    ← inferType v;
           condM (usingTransparency TransparencyMode.default $ isExprDefEqAux mvarType vType)
             (do assignExprMVar mvarId v; pure true)
             (do trace `Meta.isDefEq.assign.typeMismatch $ fun _ => mvar ++ " : " ++ mvarType ++ " := " ++ v ++ " : " ++ vType;
                 pure false)
        };
        if args.any (fun arg => mvarDecl.lctx.containsFVar arg) then
          /- We need to type check `v` because abstraction using `mkLambda` may have produced
             a type incorrect term. See discussion at A2 -/
          condM (isTypeCorrect v)
            (finalize ())
            (do trace `Meta.isDefEq.assign.typeError $ fun _ => mvar ++ " := " ++ v;
                useFOApprox ())
        else
          finalize ()

/-- Tries to solve `?m a₁ ... aₙ =?= v` by assigning `?m`.
    It assumes `?m` is unassigned. -/
private def processAssignment (mvarApp : Expr) (v : Expr) : MetaM Bool :=
traceCtx `Meta.isDefEq.assign $ do
  trace! `Meta.isDefEq.assign (mvarApp ++ " := " ++ v);
  let mvar := mvarApp.getAppFn;
  mvarDecl ← getMVarDecl mvar.mvarId!;
  processAssignmentAux mvar mvarDecl v 0 mvarApp.getAppArgs

private def isDeltaCandidate (t : Expr) : MetaM (Option ConstantInfo) :=
match t.getAppFn with
| Expr.const c _ _ => getConst c
| _                => pure none

/-- Auxiliary method for isDefEqDelta -/
private def isListLevelDefEq (us vs : List Level) : MetaM LBool :=
toLBoolM $ isListLevelDefEqAux us vs

/-- Auxiliary method for isDefEqDelta -/
private def isDefEqLeft (fn : Name) (t s : Expr) : MetaM LBool := do
trace! `Meta.isDefEq.delta.unfoldLeft fn;
toLBoolM $ isExprDefEqAux t s

/-- Auxiliary method for isDefEqDelta -/
private def isDefEqRight (fn : Name) (t s : Expr) : MetaM LBool := do
trace! `Meta.isDefEq.delta.unfoldRight fn;
toLBoolM $ isExprDefEqAux t s

/-- Auxiliary method for isDefEqDelta -/
private def isDefEqLeftRight (fn : Name) (t s : Expr) : MetaM LBool := do
trace! `Meta.isDefEq.delta.unfoldLeftRight fn;
toLBoolM $ isExprDefEqAux t s

/-- Try to solve `f a₁ ... aₙ =?= f b₁ ... bₙ` by solving `a₁ =?= b₁, ..., aₙ =?= bₙ`.

    Auxiliary method for isDefEqDelta -/
private def tryHeuristic (t s : Expr) : MetaM Bool :=
let tFn := t.getAppFn;
let sFn := s.getAppFn;
traceCtx `Meta.isDefEq.delta $
  try $ do
    b ← isDefEqArgs tFn t.getAppArgs s.getAppArgs
        <&&>
        isListLevelDefEqAux tFn.constLevels! sFn.constLevels!;
    unless b $ trace! `Meta.isDefEq.delta ("heuristic failed " ++ t ++ " =?= " ++ s);
    pure b

/-- Auxiliary method for isDefEqDelta -/
private abbrev unfold {α} (e : Expr) (failK : MetaM α) (successK : Expr → MetaM α) : MetaM α := do
e? ← unfoldDefinition e;
match e? with
| some e => successK e
| none   => failK

/-- Auxiliary method for isDefEqDelta -/
private def unfoldBothDefEq (fn : Name) (t s : Expr) : MetaM LBool :=
match t, s with
| Expr.const _ ls₁ _, Expr.const _ ls₂ _ => isListLevelDefEq ls₁ ls₂
| Expr.app _ _ _,     Expr.app _ _ _     =>
  condM (tryHeuristic t s)
    (pure LBool.true)
    (unfold t
      (unfold s (pure LBool.false) (fun s => isDefEqRight fn t s))
      (fun t => unfold s (isDefEqLeft fn t s) (fun s => isDefEqLeftRight fn t s)))
| _, _ => pure LBool.false

private def sameHeadSymbol (t s : Expr) : Bool :=
match t.getAppFn, s.getAppFn with
| Expr.const c₁ _ _, Expr.const c₂ _ _ => true
| _,                 _                 => false

/--
  - If headSymbol (unfold t) == headSymbol s, then unfold t
  - If headSymbol (unfold s) == headSymbol t, then unfold s
  - Otherwise unfold t and s if possible.

  Auxiliary method for isDefEqDelta -/
private def unfoldComparingHeadsDefEq (tInfo sInfo : ConstantInfo) (t s : Expr) : MetaM LBool :=
unfold t
  (unfold s
    (pure LBool.undef) -- `t` and `s` failed to be unfolded
    (fun s => isDefEqRight sInfo.name t s))
  (fun tNew =>
    if sameHeadSymbol tNew s then
      isDefEqLeft tInfo.name tNew s
    else
      unfold s
        (isDefEqLeft tInfo.name tNew s)
        (fun sNew =>
          if sameHeadSymbol t sNew then
            isDefEqRight sInfo.name t sNew
          else
            isDefEqLeftRight tInfo.name tNew sNew))

/-- If `t` and `s` do not contain metavariables, then use
    kernel definitional equality heuristics.
    Otherwise, use `unfoldComparingHeadsDefEq`.

    Auxiliary method for isDefEqDelta -/
private def unfoldDefEq (tInfo sInfo : ConstantInfo) (t s : Expr) : MetaM LBool :=
if !t.hasExprMVar && !s.hasExprMVar then
  /- If `t` and `s` do not contain metavariables,
     we simulate strategy used in the kernel. -/
  if tInfo.hints.lt sInfo.hints then
    unfold t (unfoldComparingHeadsDefEq tInfo sInfo t s) $ fun t => isDefEqLeft tInfo.name t s
  else if sInfo.hints.lt tInfo.hints then
    unfold s (unfoldComparingHeadsDefEq tInfo sInfo t s) $ fun s => isDefEqRight sInfo.name t s
  else
    unfoldComparingHeadsDefEq tInfo sInfo t s
else
  unfoldComparingHeadsDefEq tInfo sInfo t s

/--
  When `TransparencyMode` is set to `default` or `all`.
  If `t` is reducible and `s` is not ==> `isDefEqLeft  (unfold t) s`
  If `s` is reducible and `t` is not ==> `isDefEqRight t (unfold s)`

  Otherwise, use `unfoldDefEq`

  Auxiliary method for isDefEqDelta -/
private def unfoldReducibeDefEq (tInfo sInfo : ConstantInfo) (t s : Expr) : MetaM LBool :=
condM shouldReduceReducibleOnly
  (unfoldDefEq tInfo sInfo t s)
  (do tReducible ← isReducible tInfo.name;
      sReducible ← isReducible sInfo.name;
      if tReducible && !sReducible then
        unfold t (unfoldDefEq tInfo sInfo t s) $ fun t => isDefEqLeft tInfo.name t s
      else if !tReducible && sReducible then
        unfold s (unfoldDefEq tInfo sInfo t s) $ fun s => isDefEqRight sInfo.name t s
      else
        unfoldDefEq tInfo sInfo t s)

/--
  If `t` is a projection function application and `s` is not ==> `isDefEqRight t (unfold s)`
  If `s` is a projection function application and `t` is not ==> `isDefEqRight (unfold t) s`

  Otherwise, use `unfoldReducibeDefEq`

  Auxiliary method for isDefEqDelta -/
private def unfoldNonProjFnDefEq (tInfo sInfo : ConstantInfo) (t s : Expr) : MetaM LBool := do
env ← getEnv;
let tProj? := env.isProjectionFn tInfo.name;
let sProj? := env.isProjectionFn sInfo.name;
if tProj? && !sProj? then
  unfold s (unfoldDefEq tInfo sInfo t s) $ fun s => isDefEqRight sInfo.name t s
else if !tProj? && sProj? then
  unfold t (unfoldDefEq tInfo sInfo t s) $ fun t => isDefEqLeft tInfo.name t s
else
  unfoldReducibeDefEq tInfo sInfo t s

/--
  isDefEq by lazy delta reduction.
  This method implements many different heuristics:
  1- If only `t` can be unfolded => then unfold `t` and continue
  2- If only `s` can be unfolded => then unfold `s` and continue
  3- If `t` and `s` can be unfolded and they have the same head symbol, then
     a) First try to solve unification by unifying arguments.
     b) If it fails, unfold both and continue.
     Implemented by `unfoldBothDefEq`
  4- If `t` is a projection function application and `s` is not => then unfold `s` and continue.
  5- If `s` is a projection function application and `t` is not => then unfold `t` and continue.
  Remark: 4&5 are implemented by `unfoldNonProjFnDefEq`
  6- If `t` is reducible and `s` is not => then unfold `t` and continue.
  7- If `s` is reducible and `t` is not => then unfold `s` and continue
  Remark: 6&7 are implemented by `unfoldReducibeDefEq`
  8- If `t` and `s` do not contain metavariables, then use heuristic used in the Kernel.
     Implemented by `unfoldDefEq`
  9- If `headSymbol (unfold t) == headSymbol s`, then unfold t and continue.
  10- If `headSymbol (unfold s) == headSymbol t`, then unfold s
  11- Otherwise, unfold `t` and `s` and continue.
  Remark: 9&10&11 are implemented by `unfoldComparingHeadsDefEq` -/
private def isDefEqDelta (t s : Expr) : MetaM LBool := do
tInfo? ← isDeltaCandidate t.getAppFn;
sInfo? ← isDeltaCandidate s.getAppFn;
match tInfo?, sInfo? with
| none,       none       => pure LBool.undef
| some tInfo, none       => unfold t (pure LBool.undef) $ fun t => isDefEqLeft tInfo.name t s
| none,       some sInfo => unfold s (pure LBool.undef) $ fun s => isDefEqRight sInfo.name t s
| some tInfo, some sInfo =>
  if tInfo.name == sInfo.name then
    unfoldBothDefEq tInfo.name t s
  else
    unfoldNonProjFnDefEq tInfo sInfo t s

private def isAssigned : Expr → MetaM Bool
| Expr.mvar mvarId _ => isExprMVarAssigned mvarId
| _                  => pure false

private def isSynthetic : Expr → MetaM Bool
| Expr.mvar mvarId _ => isSyntheticExprMVar mvarId
| _                  => pure false

private def isAssignable : Expr → MetaM Bool
| Expr.mvar mvarId _ => do b ← isReadOnlyOrSyntheticExprMVar mvarId; pure (!b)
| _                  => pure false

private def etaEq (t s : Expr) : Bool :=
match t.etaExpanded? with
| some t => t == s
| none   => false

private def isLetFVar (fvarId : FVarId) : MetaM Bool := do
decl ← getLocalDecl fvarId;
pure decl.isLet

private partial def isDefEqQuick : Expr → Expr → MetaM LBool
| Expr.lit  l₁ _,           Expr.lit l₂ _            => pure (l₁ == l₂).toLBool
| Expr.sort u _,            Expr.sort v _            => toLBoolM $ isLevelDefEqAux u v
| t@(Expr.lam _ _ _ _),     s@(Expr.lam _ _ _ _)     => if t == s then pure LBool.true else toLBoolM $ isDefEqBinding t s
| t@(Expr.forallE _ _ _ _), s@(Expr.forallE _ _ _ _) => if t == s then pure LBool.true else toLBoolM $ isDefEqBinding t s
| Expr.mdata _ t _,         s                        => isDefEqQuick t s
| t,                        Expr.mdata _ s _         => isDefEqQuick t s
| Expr.fvar fvarId₁ _,      Expr.fvar fvarId₂ _      =>
  condM (isLetFVar fvarId₁ <||> isLetFVar fvarId₂)
    (pure LBool.undef)
    (pure (fvarId₁ == fvarId₂).toLBool)
| t, s =>
  cond (t == s) (pure LBool.true) $
  cond (etaEq t s || etaEq s t) (pure LBool.true) $  -- t =?= (fun xs => t xs)
  let tFn := t.getAppFn;
  let sFn := s.getAppFn;
  cond (!tFn.isMVar && !sFn.isMVar) (pure LBool.undef) $
  condM (isAssigned tFn) (do t ← instantiateMVars t; isDefEqQuick t s)  $
  condM (isAssigned sFn) (do s ← instantiateMVars s; isDefEqQuick t s) $
  condM (isSynthetic tFn <&&> synthPending tFn) (do t ← instantiateMVars t; isDefEqQuick t s) $
  condM (isSynthetic sFn <&&> synthPending sFn) (do s ← instantiateMVars s; isDefEqQuick t s) $ do
  tAssign? ← isAssignable tFn;
  sAssign? ← isAssignable sFn;
  let assign (t s : Expr) : MetaM LBool := toLBoolM $ processAssignment t s;
  cond (tAssign? && !sAssign?)  (assign t s) $
  cond (!tAssign? && sAssign?)  (assign s t) $
  cond (!tAssign? && !sAssign?)
    (if tFn.isMVar || sFn.isMVar then do
       ctx ← read;
       if ctx.config.isDefEqStuckEx then throwEx $ Exception.isExprDefEqStuck t s
       else pure LBool.false
     else pure LBool.undef) $ do
  -- Both `t` and `s` are terms of the form `?m ...`
  tMVarDecl ← getMVarDecl tFn.mvarId!;
  sMVarDecl ← getMVarDecl sFn.mvarId!;
  cond (!sMVarDecl.lctx.isSubPrefixOf tMVarDecl.lctx) (assign s t) $
  /-
    Local context for `s` is a sub prefix of the local context for `t`.

    Remark:
    It is easier to solve the assignment
        ?m2 := ?m1 a_1 ... a_n
    than
        ?m1 a_1 ... a_n := ?m2
    Reason: the first one has a precise solution. For example,
    consider the constraint `?m1 ?m =?= ?m2` -/
  cond (!t.isApp && s.isApp) (assign t s) $
  cond (!s.isApp && t.isApp && tMVarDecl.lctx.isSubPrefixOf sMVarDecl.lctx) (assign s t) $
  assign t s

private def isDefEqProofIrrel (t s : Expr) : MetaM LBool := do
status ← isProofQuick t;
match status with
| LBool.false =>
  pure LBool.undef
| LBool.true  => do
  tType ← inferType t;
  sType ← inferType s;
  toLBoolM $ isExprDefEqAux tType sType
| LBool.undef => do
  tType ← inferType t;
  condM (isProp tType)
    (do sType ← inferType s; toLBoolM $ isExprDefEqAux tType sType)
    (pure LBool.undef)

@[inline] def tryL (x : MetaM LBool) (k : MetaM Bool) : MetaM Bool := do
status ← x;
match status with
| LBool.true  => pure true
| LBool.false => pure false
| LBool.undef => k

@[specialize] private partial def isDefEqWHNF
    (t s : Expr)
    (k : Expr → Expr → MetaM Bool) : MetaM Bool := do
t' ← whnfCore t;
s' ← whnfCore s;
if t == t' && s == s' then
  k t' s'
else
  tryL (isDefEqQuick t' s') $ k t' s'

@[specialize] private def unstuckMVar
    (e : Expr)
    (successK : Expr → MetaM Bool) (failK : MetaM Bool): MetaM Bool := do
s? ← WHNF.getStuckMVar getConst whnf e;
match s? with
| some s =>
  condM (synthPending s)
    (do e ← instantiateMVars e; successK e)
    failK
| none   => failK

private def isDefEqOnFailure (t s : Expr) : MetaM Bool :=
unstuckMVar t (fun t => isExprDefEqAux t s) $
unstuckMVar s (fun s => isExprDefEqAux t s) $
pure false

partial def isExprDefEqAuxImpl : Expr → Expr → MetaM Bool
| t, s => do
  trace `Meta.isDefEq.step $ fun _ => t ++ " =?= " ++ s;
  tryL (isDefEqQuick t s) $
  tryL (isDefEqProofIrrel t s) $
  isDefEqWHNF t s $ fun t s => do
  tryL (isDefEqOffset t s) $ do
  tryL (isDefEqDelta t s) $
  condM (isDefEqEta t s <||> isDefEqEta s t) (pure true) $
  match t, s with
  | Expr.const c us _, Expr.const d vs _ => if c == d then isListLevelDefEqAux us vs else pure false
  | Expr.app _ _ _,    Expr.app _ _ _    =>
    let tFn := t.getAppFn;
    condM (try (isExprDefEqAux tFn s.getAppFn <&&> isDefEqArgs tFn t.getAppArgs s.getAppArgs))
      (pure true)
      (isDefEqOnFailure t s)
  | _, _ => isDefEqOnFailure t s

@[init] def setIsExprDefEqAuxRef : IO Unit :=
isExprDefEqAuxRef.set isExprDefEqAuxImpl

@[init] private def regTraceClasses : IO Unit := do
registerTraceClass `Meta.isDefEq;
registerTraceClass `Meta.isDefEq.foApprox;
registerTraceClass `Meta.isDefEq.delta;
registerTraceClass `Meta.isDefEq.step;
registerTraceClass `Meta.isDefEq.assign

end Meta
end Lean
