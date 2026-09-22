; regex.scm — SRFI-115 SRE matcher (tier 15A), in pure Scheme so it is
; fuel-bounded like any guest code (no ad-hoc step cap). Loaded at session init
; alongside the prelude; not a library — always available. Design: docs/regex.md.
;
; SRE subset: char / string / any / bos / eos, seq / or / * / + / ?, submatch
; (and $), char ranges (/ ...), complement (~ ...), named classes
; (alpha num alnum space). A match object is a vector: index 0 the whole match,
; 1..n the submatches (or #f).
;
; Matching is CPS-backtracking: (%re re s pos len subs k) calls (k pos2 subs2)
; on a successful match of `re`, else returns #f; the success continuation `k`
; drives backtracking (a branch retries when k returns #f). `subs` is a
; functional alist (submatch-node . (start . end)) — pure, threaded through k.

(define (%re re s pos len subs k)
  (cond ((char? re)
         (if (and (< pos len) (char=? (string-ref s pos) re)) (k (+ pos 1) subs) #f))
        ((string? re) (%re-string re s pos len subs k 0))
        ((symbol? re) (%re-sym re s pos len subs k))
        ((pair? re) (%re-compound re s pos len subs k))
        (else #f)))

(define (%re-string str s pos len subs k i)
  (cond ((= i (string-length str)) (k pos subs))
        ((and (< pos len) (char=? (string-ref s pos) (string-ref str i)))
         (%re-string str s (+ pos 1) len subs k (+ i 1)))
        (else #f)))

(define (%re-class name c)
  (cond ((eq? name 'any) #t)
        ((eq? name 'alpha) (char-alphabetic? c))
        ((eq? name 'num) (char-numeric? c))
        ((eq? name 'alnum) (or (char-alphabetic? c) (char-numeric? c)))
        ((eq? name 'space) (char-whitespace? c))
        (else #f)))

(define (%re-sym re s pos len subs k)
  (cond ((eq? re 'bos) (if (= pos 0) (k pos subs) #f))
        ((eq? re 'eos) (if (= pos len) (k pos subs) #f))
        ((>= pos len) #f)
        ((%re-class re (string-ref s pos)) (k (+ pos 1) subs))
        (else #f)))

(define (%re-compound re s pos len subs k)
  (let ((op (car re)) (args (cdr re)))
    (cond
      ((eq? op 'seq) (%re-seq args s pos len subs k))
      ((eq? op 'or) (%re-or args s pos len subs k))
      ((eq? op '?) (or (%re-seq args s pos len subs k) (k pos subs)))
      ((eq? op '*) (%re-star args s pos len subs k))
      ((eq? op '+)
       (%re-seq args s pos len subs (lambda (p2 s2) (%re-star args s p2 len s2 k))))
      ((or (eq? op 'submatch) (eq? op '$))
       (%re-seq args s pos len subs
                (lambda (p2 s2) (k p2 (cons (cons re (cons pos p2)) s2)))))
      ((eq? op '/)
       (if (and (< pos len) (%in-ranges args (string-ref s pos))) (k (+ pos 1) subs) #f))
      ((eq? op '~)
       (if (and (< pos len) (not (%in-union args (string-ref s pos)))) (k (+ pos 1) subs) #f))
      (else #f))))

(define (%re-seq items s pos len subs k)
  (if (null? items)
      (k pos subs)
      (%re (car items) s pos len subs
           (lambda (p2 s2) (%re-seq (cdr items) s p2 len s2 k)))))

(define (%re-or alts s pos len subs k)
  (if (null? alts)
      #f
      (or (%re (car alts) s pos len subs k)
          (%re-or (cdr alts) s pos len subs k))))

; greedy: try one more occurrence (requiring progress, to avoid empty-match
; loops), else stop and hand off to k.
(define (%re-star items s pos len subs k)
  (or (%re-seq items s pos len subs
              (lambda (p2 s2) (if (> p2 pos) (%re-star items s p2 len s2 k) #f)))
      (k pos subs)))

; -- character sets -------------------------------------------------------

(define (%range-endpoints args)
  (cond ((null? args) '())
        ((char? (car args)) (cons (car args) (%range-endpoints (cdr args))))
        ((string? (car args)) (append (string->list (car args)) (%range-endpoints (cdr args))))
        (else '())))

(define (%ranges-loop eps c)
  (cond ((null? eps) #f)
        ((null? (cdr eps)) #f)
        ((and (char<=? (car eps) c) (char<=? c (cadr eps))) #t)
        ((and (char<=? (cadr eps) c) (char<=? c (car eps))) #t)
        (else (%ranges-loop (cddr eps) c))))

(define (%in-ranges args c) (%ranges-loop (%range-endpoints args) c))

(define (%set-contains node c)
  (cond ((char? node) (char=? node c))
        ((string? node) (if (member c (string->list node)) #t #f))
        ((symbol? node) (%re-class node c))
        ((pair? node)
         (cond ((eq? (car node) '/) (%in-ranges (cdr node) c))
               ((eq? (car node) 'or) (%in-union (cdr node) c))
               ((eq? (car node) '~) (not (%in-union (cdr node) c)))
               (else #f)))
        (else #f)))

(define (%in-union items c)
  (cond ((null? items) #f)
        ((%set-contains (car items) c) #t)
        (else (%in-union (cdr items) c))))

; -- submatch bookkeeping -------------------------------------------------

; submatch nodes in pre-order (outer before inner, left to right).
(define (%submatch-nodes re)
  (if (pair? re)
      (append (if (or (eq? (car re) 'submatch) (eq? (car re) '$)) (list re) '())
              (%submatch-list (cdr re)))
      '()))
(define (%submatch-list items)
  (if (pair? items)
      (append (%submatch-nodes (car items)) (%submatch-list (cdr items)))
      '()))

; -- entry points ---------------------------------------------------------

; leftmost match anywhere: (start end subs) or #f.
(define (%re-search re s)
  (let ((len (string-length s)))
    (let loop ((start 0))
      (and (<= start len)
           (let ((r (%re re s start len '() (lambda (end subs) (cons end subs)))))
             (if r (list start (car r) (cdr r)) (loop (+ start 1))))))))

(define (%submatch-string node s subs)
  (let ((cell (assq node subs)))
    (if cell (substring s (cadr cell) (cddr cell)) #f)))

(define (regexp-search re s)
  (let ((sp (%re-search re s)))
    (and sp
         (let ((start (car sp)) (end (cadr sp)) (subs (caddr sp)))
           (list->vector
             (cons (substring s start end)
                   (map (lambda (n) (%submatch-string n s subs)) (%submatch-nodes re))))))))

(define (regexp-matches? re s)
  (let ((len (string-length s)))
    (if (%re re s 0 len '() (lambda (end subs) (= end len))) #t #f)))

(define (regexp-match-submatch m i) (vector-ref m i))

; -- replacement (15A.3): subst is a string, an integer (submatch index,
;    0 = whole), 'pre, 'post, or a list of these. First match only.

(define (%subst-ref i re s start end subs)
  (if (= i 0)
      (substring s start end)
      (let ((cell (assq (list-ref (%submatch-nodes re) (- i 1)) subs)))
        (if cell (substring s (cadr cell) (cddr cell)) ""))))

(define (%expand-subst subst re s start end subs)
  (cond ((string? subst) subst)
        ((integer? subst) (%subst-ref subst re s start end subs))
        ((eq? subst 'pre) (substring s 0 start))
        ((eq? subst 'post) (substring s end (string-length s)))
        ((null? subst) "")
        ((pair? subst)
         (string-append (%expand-subst (car subst) re s start end subs)
                        (%expand-subst (cdr subst) re s start end subs)))
        (else "")))

(define (regexp-replace re s subst)
  (let ((sp (%re-search re s)))
    (if sp
        (let ((start (car sp)) (end (cadr sp)) (subs (caddr sp)))
          (string-append (substring s 0 start)
                         (%expand-subst subst re s start end subs)
                         (substring s end (string-length s))))
        s)))
