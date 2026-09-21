; Pingo standard prelude (semantics §7): R5RS library procedures defined in
; the language itself. Runs at session init under an internal budget; grants
; no authority. Names starting with % are internal helpers by convention.
;
; Written in Scheme on purpose: procedures built on cons/list compose with
; pending values (non-strict cons), which a strict Zig primitive would break.

; Shadow-proof aliases used by quasiquote expansion (§2): rebinding cons or
; append must not corrupt template construction.
(define %qq-cons cons)
(define %qq-append append)
(define %qq-list list)
(define %qq-list->vector list->vector)

(define (caar p) (car (car p)))
(define (cadr p) (car (cdr p)))
(define (cdar p) (cdr (car p)))
(define (cddr p) (cdr (cdr p)))
(define (caddr p) (car (cddr p)))
(define (cdddr p) (cdr (cddr p)))
(define (cadddr p) (car (cdddr p)))

(define (list-tail xs k) (if (= k 0) xs (list-tail (cdr xs) (- k 1))))
(define (list-ref xs k) (car (list-tail xs k)))

(define (reverse xs)
  (let loop ((xs xs) (acc '()))
    (if (null? xs) acc (loop (cdr xs) (cons (car xs) acc)))))

; Tortoise-and-hare (§1 "Cycles"): a cyclic list is not a proper list.
(define (list? x)
  (let loop ((slow x) (fast x))
    (cond ((null? fast) #t)
          ((not (pair? fast)) #f)
          (else
           (let ((fast1 (cdr fast)))
             (cond ((null? fast1) #t)
                   ((not (pair? fast1)) #f)
                   ((eq? fast1 slow) #f)
                   (else (loop (cdr slow) (cdr fast1)))))))))

(define (%map1 f xs)
  (if (null? xs) '() (cons (f (car xs)) (%map1 f (cdr xs)))))
(define (%cars xss) (%map1 car xss))
(define (%cdrs xss) (%map1 cdr xss))
(define (%any-null? xss)
  (cond ((null? xss) #f)
        ((null? (car xss)) #t)
        (else (%any-null? (cdr xss)))))

(define (map f . lists)
  (cond ((null? lists) '())
        ((null? (cdr lists)) (%map1 f (car lists)))
        (else
         (let loop ((xss lists))
           (if (%any-null? xss)
               '()
               (cons (apply f (%cars xss)) (loop (%cdrs xss))))))))

(define (for-each f . lists)
  (if (null? lists)
      (if #f #f)
      (let loop ((xss lists))
        (if (%any-null? xss)
            (if #f #f)
            (begin (apply f (%cars xss)) (loop (%cdrs xss)))))))

(define (%assoc-by pred k xs)
  (cond ((null? xs) #f)
        ((pred (caar xs) k) (car xs))
        (else (%assoc-by pred k (cdr xs)))))
(define (assq k xs) (%assoc-by eq? k xs))
(define (assv k xs) (%assoc-by eqv? k xs))
(define (assoc k xs) (%assoc-by equal? k xs))

(define (%member-by pred k xs)
  (cond ((null? xs) #f)
        ((pred (car xs) k) xs)
        (else (%member-by pred k (cdr xs)))))
(define (memq k xs) (%member-by eq? k xs))
(define (memv k xs) (%member-by eqv? k xs))
(define (member k xs) (%member-by equal? k xs))

(define (abs n) (if (< n 0) (- n) n))

(define (even? n) (= 0 (remainder n 2)))
(define (odd? n) (not (even? n)))

(define (%gcd2 a b) (if (zero? b) (abs a) (%gcd2 b (remainder a b))))
(define (gcd . ns)
  (let loop ((acc 0) (ns ns))
    (if (null? ns) acc (loop (%gcd2 acc (car ns)) (cdr ns)))))
(define (%lcm2 a b)
  (if (or (zero? a) (zero? b)) 0 (abs (* (quotient a (%gcd2 a b)) b))))
(define (lcm . ns)
  (let loop ((acc 1) (ns ns))
    (if (null? ns) acc (loop (%lcm2 acc (car ns)) (cdr ns)))))

(define (zero? n) (= n 0))
(define (positive? n) (> n 0))
(define (negative? n) (< n 0))

(define (%extremum pick a rest)
  (let loop ((m a) (xs rest))
    (if (null? xs)
        m
        (loop (if (pick (car xs) m) (car xs) m) (cdr xs)))))
(define (max a . rest) (%extremum > a rest))
(define (min a . rest) (%extremum < a rest))

(define (%char-cmp cmp)
  (lambda (a . rest)
    (let loop ((prev (char->integer a)) (xs rest))
      (cond ((null? xs) #t)
            ((cmp prev (char->integer (car xs)))
             (loop (char->integer (car xs)) (cdr xs)))
            (else #f)))))
(define char=? (%char-cmp =))
(define char<? (%char-cmp <))
(define char>? (%char-cmp >))
(define char<=? (%char-cmp <=))
(define char>=? (%char-cmp >=))
(define (%ci f) (lambda args (apply f (map char-downcase args))))
(define char-ci=? (%ci char=?))
(define char-ci<? (%ci char<?))
(define char-ci>? (%ci char>?))
(define char-ci<=? (%ci char<=?))
(define char-ci>=? (%ci char>=?))
