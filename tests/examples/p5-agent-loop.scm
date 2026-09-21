; P5 — agent loop: iterations are inherently sequential (each state depends
; on the previous), but inside one iteration two independent tools run on the
; same state. The parallelism here lives in operand order freedom (§2), not
; in any list — a map/pmap cannot express it naturally.
(define step
  (lambda (state n)
    (if (eq? n 0)
        state
        (step (merge (tool-a state) (tool-b state)) (- n 1)))))
(step "initial-state" 3)
