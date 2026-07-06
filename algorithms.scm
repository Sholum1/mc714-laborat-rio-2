(use-modules (fibers conditions)
             (fibers operations)
             (goblins)
             (goblins vat)
             (goblins ocapn ids)
             (goblins ocapn captp)
             (goblins ocapn netlayer tcp-tls)
             (goblins actor-lib methods)
             (goblins actor-lib on)
             (ice-9 match)
             (ice-9 format)
             (ice-9 rdelim)
             (ice-9 threads)
             (ice-9 hash-table)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-13))

(define election-timeout 30)
(define coordinator-timeout 30)

(define (bytevector->hex bv)
  (string-join
   (map (lambda (b) (format #f "~2,'0x" b))
        (bytevector->u8-list bv))
   ""))

(define (sturdyref->id sref)
  (bytevector->hex (ocapn-sturdyref-swiss-num sref)))

;; Lamport clock

(define-actor (^lamport-clock bcom time)
  (methods
   ((tick)
    (let ((new-time (+ time 1)))
      (bcom (^lamport-clock bcom new-time) new-time)))
   ((receive remote-time)
    (let ((new-time (+ (max time remote-time) 1)))
      (bcom (^lamport-clock bcom new-time) new-time)))
   ((peek) time)))

;; Ricart–Agrawala Algorithm (Shared resource / mutual exclusion)

(define-actor (^revoked-token bcom)
  (methods
   ((write! . _) (error 'revoked "This access token has been revoked."))
   ((revoke!) #t)))

(define-actor (^access-token bcom resource)
  (methods
   ((write! new-value) ($ resource 'raw-write! new-value))
   ((revoke!) (bcom (^revoked-token bcom)))))

(define-actor (^reader bcom resource)
  (methods
   ((read!) ($ resource 'raw-read))))

(define-actor (^shared-resource bcom value current-token) #:self self
  (methods
   ((raw-write! new-value)
    (bcom (^shared-resource bcom new-value current-token)
          (format #f "OK: wrote '~a'" new-value)))
   ((raw-read) value)
   ((mint-reader!) (spawn ^reader self))
   ((grant-access!)
    (when current-token ($ current-token 'revoke!))
    (let ((fresh (spawn ^access-token self)))
      (bcom (^shared-resource bcom value fresh) fresh)))))

(define-actor (^peers-registry bcom mycapn table)
  (methods
   ((add! id sturdyref-str)
    (let ((sref (string->ocapn-id sturdyref-str)))
      (on (<- mycapn 'enliven sref)
          (lambda (peer)
            (hash-set! table id peer)
            (format #t "Peer ~a added.~%" id))
          #:catch
          (lambda (e) (format #t "Failed to add peer ~a: ~a~%" id e)))))
   ((remove! id) (hash-remove! table id))
   ((send-to! id msg)
    (let ((entry (hash-ref table id #f)))
      (if entry
          (apply <- entry msg)
          (format #t "No peer with id ~a.~%" id))))
   ((broadcast! msg)
    (hash-for-each (lambda (id p) (apply <- p msg)) table))
   ((list-ids) (hash-map->list (lambda (id p) id) table))
   ((count) (hash-count (const #t) table))))

(define-actor (^mutex-participant bcom my-id clock peers resource state) #:self self
  (methods
   ((lock! callback)
    (match state
      ('idle
       (let ((ts ($ clock 'tick)))
         ($ peers 'broadcast! (list 'mutex-request ts my-id))
         (bcom (^mutex-participant bcom my-id clock peers resource
                                    `(wanting ,ts 0 ,callback ())))))
      (_ (format #t "Already requesting/holding lock.~%"))))
   ((mutex-request! remote-ts remote-id)
    (let ((decision (match state
                      ('idle #t)
                      (`(wanting ,our-ts ,_ ,_ ,_)
                       (or (< remote-ts our-ts)
                           (and (= remote-ts our-ts) (string<? remote-id my-id))))
                      (_ #f))))
      (if decision
          ($ peers 'send-to! remote-id (list 'mutex-reply ($ clock 'tick)))
          (bcom (^mutex-participant bcom my-id clock peers resource
                                     (match state
                                       (`(wanting ,ts ,rc ,cb ,def)
                                        `(wanting ,ts ,rc ,cb ,(cons (cons remote-id remote-ts) def)))
                                       (`(held ,token ,def)
                                        `(held ,token ,(cons (cons remote-id remote-ts) def)))
                                       (_ state)))))))
   ((mutex-reply! ts)
    (match state
      (`(wanting ,our-ts ,rc ,cb ,def)
       (let ((new-rc (+ rc 1)))
         (if (>= new-rc ($ peers 'count))
             (if resource
                 (on (<- resource 'grant-access!)
                     (lambda (token)
                       ($ cb 'lock-granted token)
                       ($ self 'enter-cs! token def)))
                 (format #t ">>> ERROR: no resource connected.~%"))
             (bcom (^mutex-participant bcom my-id clock peers resource
                                        `(wanting ,our-ts ,new-rc ,cb ,def))))))
      (_ 'ignored)))
   ((enter-cs! token def)
    (bcom (^mutex-participant bcom my-id clock peers resource `(held ,token ,def))))
   ((unlock!)
    (match state
      (`(held ,token ,def)
       (on (<- token 'revoke!)
           (lambda (_) ($ self 'finish-unlock! def))
           #:catch
           (lambda (e) (format #t "revoke error: ~a~%" e))))
      (_ 'ignored)))
   ((finish-unlock! def)
    (for-each (lambda (entry)
                (let ((rid (car entry)))
                  ($ peers 'send-to! rid (list 'mutex-reply ($ clock 'tick)))))
              def)
    (bcom (^mutex-participant bcom my-id clock peers resource 'idle)))
   ((set-resource! new-resource)
    (bcom (^mutex-participant bcom my-id clock peers new-resource state)))
   ((set-id! new-id)
    (bcom (^mutex-participant bcom new-id clock peers resource state)))))

;; Bully algorithm (Leader election)

(define-actor (^leader-election bcom my-id peers phase leader round pending-cb start-time) #:self self
  (methods
   ((elect! . maybe-cb)
    (let* ((cb (if (pair? maybe-cb) (car maybe-cb) pending-cb))
           (new-round (+ round 1))
           (all-ids ($ peers 'list-ids))
           (higher (filter (lambda (i) (string>? i my-id)) all-ids)))
      (format #t "my-id=~a ~% peers=~a ~% higher=~a~%" my-id all-ids higher)
      (if (null? higher)
          (begin
            (format #t "I am the leader (id=~a).~%" my-id)
            ($ peers 'broadcast! (list 'coordinator my-id))
            (when cb ($ cb 'election-result! my-id))
            (bcom (^leader-election bcom my-id peers 'idle my-id new-round #f #f)))
          (begin
            (for-each
             (lambda (id)
               (on ($ peers 'send-to! id (list 'election my-id))
                   (lambda (reply)
                     (format #t "got reply from ~a: ~a~%" id reply)
                     (match reply
                       (('election-ok _) (<- self 'got-ok! new-round))
                       (_ #t)))
                   #:catch (lambda (e)
                             (format #t "election msg to ~a failed: ~a~%" id e)
                             #t)))
             higher)
            (on (spawn-fibrous-vow (lambda () (sleep election-timeout) #t))
                (lambda (_) (<- self 'election-timeout! new-round)))
            (bcom (^leader-election bcom my-id peers 'electing leader new-round cb (current-time)))))))

   ((got-ok! for-round)
    (if (and (= for-round round) (eq? phase 'electing))
        (begin
          (on (spawn-fibrous-vow (lambda () (sleep coordinator-timeout) #t))
              (lambda (_) (<- self 'coordinator-timeout! for-round)))
          (bcom (^leader-election bcom my-id peers 'waiting-coordinator leader round pending-cb (current-time))))
        (bcom (^leader-election bcom my-id peers phase leader round pending-cb start-time))))

   ((election-timeout! for-round)
    (if (and (= for-round round) (eq? phase 'electing))
        (begin
          (format #t "election-timeout fired for round ~a~%" for-round)
          (format #t "I am the leader (id=~a).~%" my-id)
          ($ peers 'broadcast! (list 'coordinator my-id))
          (when pending-cb ($ pending-cb 'election-result! my-id))
          (bcom (^leader-election bcom my-id peers 'idle my-id round #f #f)))
        (bcom (^leader-election bcom my-id peers phase leader round pending-cb start-time))))

   ((coordinator-timeout! for-round)
    (if (and (= for-round round) (eq? phase 'waiting-coordinator))
        (begin
          (format #t "No coordinator heard — retrying election.~%")
          (<- self 'elect! pending-cb))
        (bcom (^leader-election bcom my-id peers phase leader round pending-cb start-time))))

   ((election candidate-id)
    (format #t "received election from ~a, replying ok~%" candidate-id)
    (when (eq? phase 'idle) (<- self 'elect!))
    (list 'election-ok my-id))

   ((coordinator leader-id)
    (when (or (not leader) (string>? leader-id leader))
      (unless (equal? leader-id leader)
        (format #t "New leader: ~a~%" leader-id))
      (when pending-cb ($ pending-cb 'election-result! leader-id)))
    (bcom (^leader-election bcom my-id peers 'idle
			    (if (or (not leader) (string>? leader-id leader)) leader-id leader)
                            round #f #f)))

   ((set-id! new-id)
    (bcom (^leader-election bcom new-id peers phase leader round pending-cb start-time)))

   ((get-leader) leader)

   ((get-status)
    (let ((remaining (cond
                      ((and (eq? phase 'electing) start-time)
                       (max 0 (- election-timeout (- (current-time) start-time))))
                      ((and (eq? phase 'waiting-coordinator) start-time)
                       (max 0 (- coordinator-timeout (- (current-time) start-time))))
                      (else #f))))
      (list phase leader round remaining)))))

;; Main actor (Node)

(define-actor (^node bcom my-id clock mycapn peers mutex election resource token reader) #:self self
  (methods
   ((set-id! new-id)
    (bcom (^node bcom new-id clock mycapn peers mutex election resource token reader)))
   ((connect! sturdyref-str)
    (let ((id (sturdyref->id (string->ocapn-id sturdyref-str))))
      ($ peers 'add! id sturdyref-str)))
   ((host-resource!)
    (let ((res (spawn ^shared-resource "empty" #f)))
      (on ($ mycapn 'register res 'tcp-tls)
          (lambda (sref)
            (format #t "~%>>> NODE STURDYREF:~%~a~%~%" (ocapn-id->string sref))
            ($ mutex 'set-resource! res)
            (on (<- res 'mint-reader!)
                (lambda (rdr) ($ self 'resource-hosted! res rdr))
                #:catch (lambda (e) (format #t "Failed to mint reader: ~a~%" e)))))))
   ((connect-resource! sturdyref-str)
    (on (<- mycapn 'enliven (string->ocapn-id sturdyref-str))
        (lambda (res)
          ($ mutex 'set-resource! res)
          (on (<- res 'mint-reader!)
              (lambda (rdr)
                ($ self 'resource-hosted! res rdr)
                (format #t "Connected to shared resource.~%"))
              #:catch
              (lambda (e) (format #t "Failed to mint reader: ~a~%" e))))
        #:catch
        (lambda (e) (format #t "Failed to connect resource: ~a~%" e))))
   ((resource-hosted! res rdr)
    (bcom (^node bcom my-id clock mycapn peers mutex election res token rdr)))
   ((lock!)
    ($ mutex 'lock! self))
   ((lock-granted tok)
    (format #t "Lock acquired.~%")
    (bcom (^node bcom my-id clock mycapn peers mutex election resource tok reader)))
   ((unlock!)
    (if token
        (begin
          ($ mutex 'unlock!)
          (format #t "Lock released.~%")
          (bcom (^node bcom my-id clock mycapn peers mutex election resource #f reader)))
        (format #t "No lock held.~%")))
   ((write! text)
    (if token
        (on (<- token 'write! text)
            (lambda (r) (format #t "~a~%" r))
            #:catch (lambda (e) (format #t "write error: ~a~%" e)))
        (format #t "No token held.~%")))
   ((read!)
    (if reader
        (on (<- reader 'read!)
            (lambda (r) (format #t "resource = ~a~%" r))
            #:catch (lambda (e) (format #t "read error: ~a~%" e)))
        (format #t "No resource connected.~%")))
   ((send! id text)
    (let ((ts ($ clock 'tick)))
      ($ peers 'send-to! id (list 'chat ts text))
      (format #t "(clock=~a) sent to ~a: ~a~%" ts id text)))
   ((chat ts text)
    ($ clock 'receive ts)
    (format #t "[~a] (clock=~a) received: ~a~%" my-id ($ clock 'peek) text)
    (format #f "ack from ~a" my-id))
   ((mutex-request ts rid) ($ mutex 'mutex-request! ts rid))
   ((mutex-reply ts) ($ mutex 'mutex-reply! ts))
   ((election cid) ($ election 'election cid))
   ((coordinator lid) ($ election 'coordinator lid))
   ((peers) (format #t "Peers: ~a~%" ($ peers 'list-ids)))
   ((status)
    (format #t "id=~a clock=~a token?=~a~%" my-id ($ clock 'peek) (if token "yes" "no")))
   ((elect!) ($ election 'elect! self))
   ((election-result! leader-id) (format #t "Election finished — leader is ~a~%" leader-id))
   ((election-status)
    (match ($ election 'get-status)
      ((phase leader round remaining)
       (format #t "Election phase: ~a, leader: ~a, round: ~a" phase (or leader "none") round)
       (if remaining
           (format #t ", time remaining: ~a seconds~%" remaining)
           (format #t "~%")))))
   ((get-leader)
    (let ((l ($ election 'get-leader)))
      (if l
	  (format #t "Current leader: ~a~%" l)
	  (format #t "No leader elected yet.~%"))))))

(define my-ip
  (match (cdr (command-line))
    ((ip) ip)
    (_ (error "Usage: guile algorithms.scm <my-ip>"))))

(define vat      (spawn-vat))
(define netlayer (with-vat vat (spawn ^tcp-tls-netlayer my-ip)))
(define mycapn   (with-vat vat (spawn-mycapn netlayer)))
(define clock    (with-vat vat (spawn ^lamport-clock 0)))
(define peers    (with-vat vat (spawn ^peers-registry mycapn (make-hash-table))))
(define mutex    (with-vat vat (spawn ^mutex-participant #f clock peers #f 'idle)))
(define election (with-vat vat (spawn ^leader-election #f peers 'idle #f 0 #f 0)))
(define node     (with-vat vat (spawn ^node #f clock mycapn peers mutex election #f #f #f)))

(define (help)
  (format #t "Available commands:
  help                       - this
  connect <sturdyref>        - add a peer
  send <id> <text>           - send chat message
  lock-mutex / unlock        - acquire/release mutex
  elect                      - start leader election
  election                   - get election status (phase, round, time remaining)
  host-resource              - create and share a resource
  connect-resource <sref>    - connect to a shared resource
  write <text>               - write to resource (needs lock)
  read                       - read resource
  peers                      - list connected peers
  status:                    - show node status (id, clock and token?)
  leader                     - show current leader
  quit                       - exit
"))

(with-vat vat
  (on ($ mycapn 'register node 'tcp-tls)
      (lambda (sref)
        (let ((id (sturdyref->id sref)))
          (format #t "~%>>> MY STURDYREF (id=~a):~%~a~%~%" id (ocapn-id->string sref))
          ($ node 'set-id! id)
          ($ mutex 'set-id! id)
          ($ election 'set-id! id)
          (help)))))

(define (stdin-loop)
  (let loop ()
    (let ((line (read-line)))
      (unless (eof-object? line)
        (let* ((trimmed (string-trim-both line))
               (toks (filter (lambda (s) (not (string-null? s)))
                             (string-split trimmed #\space))))
          (with-vat vat
            (match toks
              (() #t)
	      (("help") (help))
	      (("connect" sturdyref) ($ node 'connect! sturdyref))
	      (("send" id . txt) ($ node 'send! (string->number id) (string-join txt " ")))
              (("lock") ($ node 'lock!))
              (("unlock") ($ node 'unlock!))
              (("elect") ($ node 'elect!))
	      (("election") ($ node 'election-status))
              (("host-resource") ($ node 'host-resource!))
              (("connect-resource" sturdyref) ($ node 'connect-resource! sturdyref))
              (("write" . txt) ($ node 'write! (string-join txt " ")))
              (("read") ($ node 'read!))
              (("peers") ($ node 'peers))
              (("status") ($ node 'status))
	      (("leader") ($ node 'get-leader))
              (("quit") (primitive-exit 0))
              (other (format #t "Unknown command: ~a~%" (string-join other " "))))))
        (loop)))))

(call-with-new-thread stdin-loop)
(perform-operation (wait-operation (make-condition)))
