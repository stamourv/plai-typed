#lang scheme/base
(require scheme/list
         scheme/pretty
         (for-template scheme/contract
                       scheme/base))

(provide gen-tvar make-bool make-num make-sym make-str make-vd make-sexp
         make-arrow make-listof make-boxof make-tupleof make-vectorof make-datatype
         to-contract
         create-defn
         make-poly poly-instance at-source instantiate-constructor-at
         current-timestamp
         unify! unify-defn!
         let-based-poly
         lookup
         type->datum)

(define-struct type ([src #:mutable]))

(define-struct (tvar type) ([rep #:mutable] timestamp) #:transparent)
(define-struct (arrow-tvar tvar) ()) ; must unify with arrow
(define-struct (bool type) ())
(define-struct (num type) ())
(define-struct (sym type) ())
(define-struct (sexp type) ())
(define-struct (vd type) ())
(define-struct (str type) ())
(define-struct (arrow type) (args result) #:transparent)
(define-struct (listof type) (element))
(define-struct (boxof type) (element))
(define-struct (vectorof type) (element))
(define-struct (tupleof type) (args))
(define-struct (datatype type) (id args))
(define-struct (poly type) (tvar type) #:transparent)
(define-struct (defn type) (base [rhs #:mutable] [insts #:mutable] [proto-rhs #:mutable]) #:transparent)

(define (to-contract type)
  (let/ec k
    (let loop ([type type]
               [inside-mutable? #f])
      (cond
        [(defn? type) 
         ;; is this the right thing?
         (if (defn-rhs type)
             (loop (defn-rhs type) inside-mutable?)
             (loop (car (defn-proto-rhs type)) inside-mutable?))]
        [(bool? type) #'boolean?]
        [(num? type) #'number?]
        [(sym? type) #'symbol?]
        [(sexp? type) #'(letrec ([s-exp? (recursive-contract (or/c symbol? number? string? (listof s-exp?)))])
                          s-exp?)]
        [(void? type) #'void?]
        [(str? type) #'string?]
        [(arrow? type)
         (if inside-mutable?  ;; need better support for mutable data structure contracts.
             (k #'any/c)
             #`(-> #,@(map (λ (x) (loop x inside-mutable?)) (arrow-args type))
                   #,(loop (arrow-result type) inside-mutable?)))]
        [(listof? type) #`(listof #,(loop (listof-element type) inside-mutable?))]
        [(boxof? type) #`(box/c #,(loop (boxof-element type) #t))]
        [(vectorof? type) #`(vectorof #,(loop (vectorof-element type) #t))]
        [(tupleof? type) #`(vector-immutable/c #,@(map (λ (x) (loop x inside-mutable?))
                                                       (tupleof-args type)))]
        [(poly? type) (loop (poly-type type) inside-mutable?)]
        [(datatype? type) 
         (datum->syntax 
          (datatype-id type)
          (string->symbol (format "~a?" (syntax-e (datatype-id type)))))]
        [(tvar? type)
         ;; this can be done with new-∀ (in the poly? case), but only new-∃ exists at the moment
         (if (tvar-rep type)
             (loop (tvar-rep type) inside-mutable?)
             (k #'any/c))]
        [else (raise-syntax-error 'to-contract/expr
                                  (format "got confused, trying to generate a contract ~s" type) 
                                  (type-src type))]))))

(define current-timestamp 0)

(define (gen-tvar src [arrow? #f])
  (begin
    (set! current-timestamp (add1 current-timestamp))
    ((if arrow? make-arrow-tvar make-tvar) src #f current-timestamp)))

(define ((type->datum tmap) t)
  (cond
   [(tvar? t)
    (if (tvar-rep t)
        ((type->datum tmap) (tvar-rep t))
        (if (arrow-tvar? t)
            '(... -> ...)
            (let ([a (hash-ref tmap t #f)])
              (if a
                  a
                  (let ([a `',(string->symbol
                               (format "~a~a"
                                       (if (eq? (type-src t) 'poly)
                                           ""
                                           "_")
                                       (let ([n (hash-count tmap)])
                                         (if (n . < . 26)
                                             (integer->char (+ 97 n))
                                             (format "a~a" n)))))])
                    (hash-set! tmap t a)
                    a)))))]
   [(num? t) 'number]
   [(bool? t) 'boolean]
   [(sym? t) 'symbol]
   [(str? t) 'string]
   [(sexp? t) 's-expression]
   [(vd? t) 'void]
   [(arrow? t) `(,@(map (type->datum tmap) (arrow-args t))
                 ->
                 ,((type->datum tmap) (arrow-result t)))]
   [(listof? t) `(listof ,((type->datum tmap) (listof-element t)))]
   [(boxof? t) `(boxof ,((type->datum tmap) (boxof-element t)))]
   [(vectorof? t) `(vectorof ,((type->datum tmap) (vectorof-element t)))]
   [(tupleof? t) (let ([a (map (type->datum tmap) (tupleof-args t))])
                   (if (null? a)
                       '()
                       (cons (car a)
                             (let loop ([a (cdr a)])
                               (if (null? a)
                                   '()
                                   (list* '* (car a) (loop (cdr a))))))))]
   [(datatype? t) (let ([name (syntax-e (datatype-id t))])
                    (if (null? (datatype-args t))
                        name
                        `(,name ,@(map (type->datum tmap)
                                       (datatype-args t)))))]
   [(poly? t) ((type->datum tmap) ((instance (poly-tvar t)
                                             (gen-tvar 'poly))
                                   (poly-type t)))]
   [else (format "?~s" t)]))

(define ((instance old-tvar new-tvar) t)
  (cond
   [(eq? t old-tvar) new-tvar]
   [(arrow? t)
    (make-arrow (type-src t)
                (map (instance old-tvar new-tvar)
                     (arrow-args t))
                ((instance old-tvar new-tvar)
                 (arrow-result t)))]
   [(listof? t) (make-listof (type-src t)
                             ((instance old-tvar new-tvar)
                              (listof-element t)))]
   [(boxof? t) (make-boxof (type-src t)
                           ((instance old-tvar new-tvar)
                            (boxof-element t)))]
   [(vectorof? t) (make-vectorof (type-src t)
                                 ((instance old-tvar new-tvar)
                                  (vectorof-element t)))]
   [(tupleof? t) (make-tupleof (type-src t)
                               (map (instance old-tvar new-tvar)
                                    (tupleof-args t)))]
   [(poly? t) (make-poly (type-src t)
                         (poly-tvar t)
                         ((instance old-tvar new-tvar)
                          (poly-type t)))]
   [(datatype? t) (if (null? (datatype-args t))
                      t
                      (make-datatype (type-src t)
                                     (datatype-id t)
                                     (map (instance old-tvar new-tvar)
                                          (datatype-args t))))]
   [else t]))
(define (extract-tvars pre-ts post-ts pre-ts2 post-ts2 t)
  (let ([tvars
         (let loop ([t t])
           (cond
            [(tvar? t) 
             (if (let ([ts (tvar-timestamp t)])
                   (or (and (ts . > . pre-ts) (ts . <= . post-ts))
                       (and (ts . > . pre-ts2) (ts . <= . post-ts2))))
                 (list t)
                 null)]
            [(arrow? t)
             (append (loop (arrow-result t))
                     (apply append
                            (map loop (arrow-args t))))]
            [(listof? t) (loop (listof-element t))]
            [(boxof? t) (loop (boxof-element t))]
            [(vectorof? t) (loop (vectorof-element t))]
            [(tupleof? t) (apply append
                                 (map loop (tupleof-args t)))]
            [(datatype? t) (apply append
                                  (map loop (datatype-args t)))]
            [(poly? t) (remq* (list (poly-tvar t))
                              (loop (poly-type t)))]
            [else null]))])
    (if (null? tvars)
        null
        (let ([ht (make-hasheq)])
          (for-each (lambda (t)
                      (hash-set! ht t #t))
                    tvars)
          (hash-map ht (lambda (k v) k))))))

(define (poly-instance t)
  (cond
   [(defn? t)
    (if (defn-rhs t)
        ;; Type is determined:
        (poly-instance (defn-rhs t))
        ;; We only have a skeleton...
        (let ([inst (poly-instance (defn-base t))])
          ;; Remember this intance to check the type later:
          (set-defn-insts! t (cons (cons #f inst) (defn-insts t)))
          inst))]
   [(tvar? t)
    (let ([t (simplify! t)])
      (if (poly? t)
          (poly-instance t)
          t))]
   [(poly? t)
    (poly-instance
     ((instance (poly-tvar t)
                (gen-tvar #f))
      (poly-type t)))]
   [else t]))

(define (instantiate-constructor-at type datatype)
  (let loop ([type type]
             [orig-poly null])
    (cond
     [(poly? type)
      (loop (poly-type type)
            (cons (poly-tvar type) orig-poly))]
     [else
      (unless (= (length orig-poly)
                 (length (datatype-args datatype)))
        (error "constructor abstraction mismatch"))
      (let loop ([type type]
                 [orig (reverse orig-poly)]
                 [new (datatype-args datatype)])
        (if (null? orig)
            type
            (loop ((instance (car orig) (car new)) type)
                  (cdr orig)
                  (cdr new))))])))

(define (create-defn timestamp t)
  (let ([p (poly-ize t timestamp current-timestamp 0 0)])
    (make-defn (type-src t)
               p
               (if (poly? p) #f p)
               null
               #f)))

(define (poly-ize t pre-ts post-ts pre-ts2 post-ts2)
  (let loop ([tvars (extract-tvars pre-ts post-ts pre-ts2 post-ts2 t)][t t])
    (cond
     [(null? tvars) t]
     [else (loop (cdr tvars)
                 (make-poly (type-src t)
                            (car tvars)
                            t))])))

(define (at-source t expr)
  (let ([t (clone t +inf.0)])
    (let loop ([t t])
      (add-srcs! t expr)
      (cond
       [(arrow? t) 
        (for-each loop (arrow-args t))
        (loop (arrow-result t))]
       [(listof? t)
        (loop (listof-element t))]
       [(boxof? t)
        (loop (boxof-element t))]
       [(vectorof? t)
        (loop (vectorof-element t))]
       [(tupleof? t)
        (for-each loop (tupleof-args t))]
       [(datatype? t)
        (for-each loop (datatype-args t))]))
    t))

(define (clone t ts)
  (cond
   [(tvar? t) (if (tvar-rep t)
                  (clone (tvar-rep t) ts)
                  (if ((tvar-timestamp t) . > . ts)
                      ;; to let-bound polymorphism, we need
                      ;; only older vars
                      (let ([t2 ((if (arrow-tvar? t) make-arrow-tvar make-tvar)
                                 (type-src t)
                                 #f
                                 ts)])
                        (set-tvar-rep! t t2)
                        t2)
                      t))]
   [(bool? t) (make-bool (type-src t))]
   [(num? t) (make-num (type-src t))]
   [(sym? t) (make-sym (type-src t))]
   [(sexp? t) (make-sexp (type-src t))]
   [(str? t) (make-str (type-src t))]
   [(vd? t) (make-vd (type-src t))]
   [(arrow? t) (make-arrow
                (type-src t)
                (map (lambda (t) (clone t ts)) (arrow-args t))
                (clone (arrow-result t) ts))]
   [(listof? t) (make-listof
                 (type-src t)
                 (clone (listof-element t) ts))]
   [(boxof? t) (make-boxof
                (type-src t)
                (clone (boxof-element t) ts))]
   [(vectorof? t) (make-vectorof
                   (type-src t)
                   (clone (vectorof-element t) ts))]
   [(tupleof? t) (make-tupleof
                  (type-src t)
                  (map (lambda (t) (clone t ts)) (tupleof-args t)))]
   [(datatype? t) (make-datatype
                   (type-src t)
                   (datatype-id t)
                   (map (lambda (t) (clone t ts)) (datatype-args t)))]
   [(poly? t) (error 'clone "shouldn't clone poly")]
   [else (error 'clone "unrecognized: ~e" t)]))

(define (extract-srcs! r ht)
  (cond
   [(not r) (void)]
   [(syntax? r)
    (hash-set! ht r #t)]
   [(type? r) (extract-srcs! (type-src r) ht)]
   [(list? r) (map (lambda (i)
                     (extract-srcs! i ht))
                   r)]))

(define raise-typecheck-error
  (case-lambda
   [(main-expr a b reason)
    (let ([exprs (let ([ht (make-hasheq)])
                   (extract-srcs! a ht)
                   (extract-srcs! b ht)
                   (hash-map ht (lambda (k v) k)))])
      (raise
       (make-exn:fail:syntax
        (parameterize ([print-as-expression #f])
          (format "typecheck failed~a: ~a vs ~a"
                  (if reason
                      (format " (~a)" reason)
                      "")
                  (pretty-format ((type->datum (make-hasheq)) a))
                  (pretty-format ((type->datum (make-hasheq)) b))))
        (current-continuation-marks)
        (apply list (if main-expr
                        (cons main-expr exprs)
                        exprs)))))]
   [(expr a b)
    (raise-typecheck-error expr a b #f)]))

(define (lookup id env)
  (or (ormap (lambda (p)
               (and (free-identifier=? id (car p))
                    (cdr p)))
             env)
      (raise-syntax-error 
       #f
       "free variable while typechecking"
       id)))

(define (add-srcs! r a)
  (let ([srcs (type-src r)])
    (cond
     [(not srcs) (set-type-src! r a)]
     [(pair? srcs) (set-type-src! r (cons a srcs))]
     [else (set-type-src! r (list a srcs))])))

(define (simplify! a)
  (if (tvar? a)
      (let ([r (let loop ([a a])
                 (if (and (tvar? a)
                          (tvar-rep a))
                     (loop (tvar-rep a))
                     a))])
        (let ([r (if (tvar? r)
                     r
                     ;; clone it so we can set the location
                     (clone r +inf.0))])
          (let loop ([a a])
            (unless (or (eq? r a)
                        (not (tvar? a)))
              (let ([r2 (tvar-rep a)])
                (set-tvar-rep! a r)
                (add-srcs! r a)
                (loop r2)))))
        r)
      a))

(define (simplify!* t)
  (cond
   [(tvar? t) (let ([t2 (simplify! t)])
                (if (tvar? t2)
                    t2
                    (simplify!* t2)))]
   [(arrow? t)
    (make-arrow (type-src t)
                (map simplify!*
                     (arrow-args t))
                (simplify!* (arrow-result t)))]
   [(listof? t) (make-listof (type-src t)
                             (simplify!* (listof-element t)))]
   [(boxof? t) (make-boxof (type-src t)
                           (simplify!* (boxof-element t)))]
   [(vectorof? t) (make-listof (type-src t)
                               (simplify!* (vectorof-element t)))]
   [(tupleof? t) (make-tupleof (type-src t)
                               (map simplify!* (tupleof-args t)))]
   [(poly? t) (make-poly (type-src t)
                         (poly-tvar t)
                         (simplify!* (poly-type t)))]
   [(datatype? t) (if (null? (datatype-args t))
                      t
                      (make-datatype (type-src t)
                                     (datatype-id t)
                                     (map simplify!*
                                          (datatype-args t))))]
   [else t]))

(define (resolve-defn-types env)
  (map (lambda (p)
         (let ([id (car p)]
               [t (cdr p)])
           (and (defn? t)
                (or (defn-rhs t)
                    (let* ([b (simplify!* (car (defn-proto-rhs t)))]
                           [poly (apply poly-ize b (cdr (defn-proto-rhs t)))])
                      (for-each (lambda (x)
                                  (unify! (car x) (cdr x) (poly-instance poly)))
                                (defn-insts t))
                      poly)))))
       env))

(define (let-based-poly env)
  (let ([defn-types
          ;; Find fixpoint of defn-type polymorphism:
          (let loop ([defn-types (resolve-defn-types env)])
            (let ([new-defn-types (resolve-defn-types env)])
              (if (andmap (lambda (a b)
                            (let loop ([a a] [b b])
                              (cond
                               [(poly? a)
                                (and (poly? b)
                                     (loop (poly-type a) (poly-type b)))]
                               [(poly? b) #f]
                               [else #t])))
                          defn-types new-defn-types)
                  new-defn-types
                  (loop new-defn-types))))])
    (map (lambda (p defn-type)
           (let ([id (car p)]
                 [t (cdr p)])
             (if (defn? t)
                 (cons id defn-type)
                 p)))
         env defn-types)))

(define (occurs? a b)
  (cond
   [(eq? a b) #t]
   [(and (tvar? b)
         (tvar-rep b))
    (occurs? a (tvar-rep b))]
   [(arrow? b)
    (or (ormap (lambda (arg)
                 (occurs? a arg))
               (arrow-args b))
        (occurs? a (arrow-result b)))]
   [(listof? b)
    (occurs? a (listof-element b))]
   [(boxof? b)
    (occurs? a (boxof-element b))]
   [(vectorof? b)
    (occurs? a (vectorof-element b))]
   [(tupleof? b)
    (ormap (lambda (arg) (occurs? a arg))
           (tupleof-args b))]
   [(datatype? b)
    (ormap (lambda (arg) (occurs? a arg))
           (datatype-args b))]
   [else #f]))

(define (unify-defn! expr a b pre-ts post-ts)
  (if (defn? a)
      (let ([pre-ts2 current-timestamp]
            [pi (poly-instance (defn-base a))]
            [post-ts2 current-timestamp])
        (unify! expr pi b)
        (unless (defn-rhs a) 
          (set-defn-proto-rhs! a (list b pre-ts post-ts pre-ts2 post-ts2))))
      (unify! expr a b)))

(define (unify! expr a b)
  (let ([a (simplify! a)]
        [b (simplify! b)])        
    (if (and (tvar? b)
             (not (tvar? a)))
        (unify! expr b a)
        (cond
         [(eq? a b) (void)]
         [(tvar? a)
          (when (occurs? a b)
            (raise-typecheck-error expr a b "cycle"))
          (if (tvar? b)
              (if (or (< (tvar-timestamp b) (tvar-timestamp a))
                      (arrow-tvar? b))
                  (begin
                    (set-tvar-rep! a b)
                    (add-srcs! b a))
                  (begin
                    (set-tvar-rep! b a)
                    (add-srcs! a b)))
              (if (and (arrow-tvar? a)
                       (not (arrow? b)))
                  (raise-typecheck-error expr a b "trace procedure")
                  (let ([b (clone b (tvar-timestamp a))])
                    (set-tvar-rep! a b)
                    (add-srcs! b a))))]
         [(bool? a)
          (unless (bool? b)
            (raise-typecheck-error expr a b))]
         [(num? a)
          (unless (num? b)
            (raise-typecheck-error expr a b))]
         [(sym? a)
          (unless (sym? b)
            (raise-typecheck-error expr a b))]
         [(sexp? a)
          (unless (sexp? b)
            (raise-typecheck-error expr a b))]
         [(vd? a)
          (unless (vd? b)
            (raise-typecheck-error expr a b))]
         [(str? a)
          (unless (str? b)
            (raise-typecheck-error expr a b))]
         [(arrow? a)
          (unless (and (arrow? b)
                       (= (length (arrow-args b))
                          (length (arrow-args a))))
            (raise-typecheck-error expr a b))
          (map (lambda (a b) (unify! expr a b)) (arrow-args a) (arrow-args b))
          (unify! expr (arrow-result a) (arrow-result b))]
         [(listof? a)
          (unless (listof? b)
            (raise-typecheck-error expr a b))
          (unify! expr (listof-element a) (listof-element b))]
         [(boxof? a)
          (unless (boxof? b)
            (raise-typecheck-error expr a b))
          (unify! expr (boxof-element a) (boxof-element b))]
         [(vectorof? a)
          (unless (vectorof? b)
            (raise-typecheck-error expr a b))
          (unify! expr (vectorof-element a) (vectorof-element b))]
         [(tupleof? a)
          (unless (and (tupleof? b)
                       (= (length (tupleof-args a))
                          (length (tupleof-args b))))
            (raise-typecheck-error expr a b))
          (map (lambda (a b) (unify! expr a b)) (tupleof-args a) (tupleof-args b))]
         [(datatype? a)
          (unless (and (datatype? b)
                       (free-identifier=? (datatype-id a)
                                          (datatype-id b)))
            (raise-typecheck-error expr a b))
          (map (lambda (a b) (unify! expr a b)) (datatype-args a) (datatype-args b))]
         [else
          (raise-typecheck-error expr a b (format "unrecognized type ~s" a))]))))