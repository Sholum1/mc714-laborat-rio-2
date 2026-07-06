#!/usr/bin/env -S guix repl --
!#

(use-modules (ice-9 format)
	     (ice-9 match)
	     (srfi srfi-1))

(define (run cmd)
  (format #t "Running: ~a\n" cmd)
  (let ((ret (system cmd)))
    (unless (zero? ret)
      (error (format #f "Command failed with exit code ~a: ~a" ret cmd)))))

(unless (zero? (getuid))
  (error "This script must be run as root (use sudo)."))

(define pids (cdr (command-line)))
(when (null? pids)
  (format #t "Usage: sudo ~a <pid1> <pid2> ...\n" (car (command-line)))
  (exit 1))

(run "sudo ip link add br0 type bridge")
(run "sudo ip addr add 10.0.0.1/24 dev br0")
(run "sudo ip link set br0 up")

(let loop ((i 1) (pids pids))
  (match pids
    (() #t)
    ((pid . rest)
     (let ((ns-name (format #f "node-~a" i))
	   (veth-name (format #f "veth-node-~a" i))
	   (ceth-name (format #f "ceth-node-~a" i))
	   (ip (format #f "10.0.0.1~a/24" i)))
       (format #t "\n--- Setting up node ~a (PID ~a) ---\n" i pid)

       (run (format #f "sudo ip netns attach ~a ~a" ns-name pid))

       (run (format #f "sudo ip link add ~a type veth peer name ~a"
		    veth-name ceth-name))

       (run (format #f "sudo ip link set ~a master br0" veth-name))
       (run (format #f "sudo ip link set ~a up" veth-name))

       (run (format #f "sudo ip link set ~a netns ~a" ceth-name ns-name))

       (run (format #f "sudo ip netns exec ~a ip link set lo up" ns-name))
       (run (format #f "sudo ip netns exec ~a ip addr add ~a dev ~a"
		    ns-name ip ceth-name))
       (run (format #f "sudo ip netns exec ~a ip link set ~a up"
		    ns-name ceth-name))

       (loop (+ i 1) rest)))))

(format #t "\nAll nodes set up successfully.\n")
