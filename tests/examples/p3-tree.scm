; P3 — tree-of-thoughts (one level, k=3): propose k candidates, score each,
; expand the best. PopPy's motivating shape: fan-out per level, sequential
; across levels.
(define map (lambda (f xs) (if (null? xs) '() (cons (f (car xs)) (map f (cdr xs))))))
(define candidates (map propose '(1 2 3)))
(define scores (map score candidates))
(expand (pick-best candidates scores))
