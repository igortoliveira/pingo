; P1 — fan-out: summarize N documents, then synthesize over all summaries.
; The dominant compound-AI shape: map over a collection of external calls.
(define map (lambda (f xs) (if (null? xs) '() (cons (f (car xs)) (map f (cdr xs))))))
(define docs '("doc-1" "doc-2" "doc-3" "doc-4"))
(synthesize (map summarize docs))
