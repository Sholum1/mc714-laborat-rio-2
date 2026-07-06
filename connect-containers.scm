#!/usr/bin/env -S guix repl --
!#

(use-modules (ice-9 format)
             (ice-9 match))

(define (exit-code status)
  (status:exit-val status))

(define (run cmd)
  (format #t "Running: ~a\n" cmd)
  (let ((status (system cmd)))
    (let ((code (exit-code status)))
      (unless (= code 0)
        (error (format #f "FAILED (~a): ~a" code cmd))))))

(unless (zero? (getuid))
  (error "Run as root"))

(define pids (cdr (command-line)))


(run "ip link delete br0 2>/dev/null || true")


(run "ip link add br0 type bridge")
(run "ip addr add 10.0.0.1/24 dev br0")
(run "ip link set br0 up")

(let loop ((i 1) (pids pids))
  (match pids
    (() #t)
    ((pid . rest)
     (let* ((ns   (format #f "node-~a" i))
            (veth (format #f "veth-node-~a" i))
            (ceth (format #f "ceth-node-~a" i))
            (ip   (format #f "10.0.0.~a/24" (+ 10 i))))

       (format #t "\n--- Node ~a ---\n" i)


       (run (format #f "ip netns attach ~a ~a" ns pid))


       (run (format #f "ip link add ~a type veth peer name ~a" veth ceth))


       (run (format #f "ip link set ~a netns ~a" ceth ns))


       (run (format #f "ip link set ~a up" veth))
       (run (format #f "ip link set ~a master br0" veth))


       (run (format #f "ip netns exec ~a ip link set lo up" ns))
       (run (format #f "ip netns exec ~a ip addr add ~a dev ~a" ns ip ceth))
       (run (format #f "ip netns exec ~a ip link set ~a up" ns ceth))

       (loop (+ i 1) rest)))))

(format #t "\nOK: all nodes connected.\n")
