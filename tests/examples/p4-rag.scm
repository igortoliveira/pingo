; P4 — RAG: rewrite the query once, retrieve from three sources with the
; rewritten query, rerank over all results, answer. Mixed shape: a bounded
; fan-out sandwiched between sequential steps.
(define q (rewrite "why is the sky blue?"))
(answer (rerank (cons (search-web q) (cons (search-wiki q) (cons (search-docs q) '())))))
