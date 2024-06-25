/-!
Tests that definitions by well-founded recursion are irreducible.
-/

def foo : Nat → Nat
  | 0 => 0
  | n+1 => foo n
termination_by n => n

/--
error: type mismatch
  rfl
has type
  foo 0 = foo 0 : Prop
but is expected to have type
  foo 0 = 0 : Prop
-/
#guard_msgs in
example : foo 0 = 0 := rfl

/--
error: type mismatch
  rfl
has type
  foo (n + 1) = foo (n + 1) : Prop
but is expected to have type
  foo (n + 1) = foo n : Prop
-/
#guard_msgs in
example : foo (n+1) = foo n := rfl

-- This succeeding is a bug or misfeature in the rfl tactic, using the kernel defeq check
#guard_msgs in
example : foo 0 = 0 := by rfl

-- It only works on closed terms:
/--
error: The rfl tactic failed. Possible reasons:
- The goal is not a reflexive relation (neither `=` nor a relation with a @[refl] lemma).
- The arguments of the relation are not equal.
Try using the reflexivity lemma for your relation explicitly, e.g. `exact Eq.refl _` or
`exact HEq.rfl` etc.
n : Nat
⊢ foo (n + 1) = foo n
-/
#guard_msgs in
example : foo (n+1) = foo n := by rfl

section Unsealed

unseal foo

example : foo 0 = 0 := rfl
example : foo 0 = 0 := by rfl

example : foo (n+1) = foo n := rfl
example : foo (n+1) = foo n := by rfl

end Unsealed

--should be sealed again here

/--
error: type mismatch
  rfl
has type
  foo 0 = foo 0 : Prop
but is expected to have type
  foo 0 = 0 : Prop
-/
#guard_msgs in
example : foo 0 = 0 := rfl


def bar : Nat → Nat
  | 0 => 0
  | n+1 => bar n
termination_by n => n

-- Once unsealed, the full internals are visible. This allows one to prove, for example

/--
error: type mismatch
  rfl
has type
  foo = foo : Prop
but is expected to have type
  foo = bar : Prop
-/
#guard_msgs in
example : foo = bar := rfl


unseal foo bar in
example : foo = bar := rfl


-- Attributes on the definition take precedence
@[semireducible] def baz : Nat → Nat
  | 0 => 0
  | n+1 => baz n
termination_by n => n

example : baz 0 = 0 := rfl

seal baz in
/--
error: type mismatch
  rfl
has type
  baz 0 = baz 0 : Prop
but is expected to have type
  baz 0 = 0 : Prop
-/
#guard_msgs in
example : baz 0 = 0 := rfl

example : baz 0 = 0 := rfl

@[reducible] def quux : Nat → Nat
  | 0 => 0
  | n+1 => quux n
termination_by n => n

example : quux 0 = 0 := rfl

set_option allowUnsafeReducibility true in
seal quux in
/--
error: type mismatch
  rfl
has type
  quux 0 = quux 0 : Prop
but is expected to have type
  quux 0 = 0 : Prop
-/
#guard_msgs in
example : quux 0 = 0 := rfl

example : quux 0 = 0 := rfl
