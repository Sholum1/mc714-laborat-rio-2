#!/usr/bin/env -S guix repl --
!#

(use-modules (ice-9 format)
             (ice-9 match)
             (srfi srfi-1))

(define (run cmd)
  (format #t "Running: ~a\n" cmd)
  (let ((ret (system cmd)))
    (unless (zero? ret)
      (format #t "Warning: command failed with exit code ~a\n" ret))))

(unless (zero? (getuid))
  (error "This script must be run as root (use sudo)."))

(define pids (cdr (command-line)))
(when (null? pids)
  (format #t "Usage: sudo ~a <pid1> <pid2> ...\n" (car (command-line)))
  (exit 1))

(let ((count (length pids)))
  (do ((i 1 (+ i 1)))
      ((> i count))
    (let ((ns   (format #f "node-~a" i))
          (veth (format #f "veth-node-~a" i)))
      (run (format #f "ip netns delete ~a" ns))

      (run (format #f "ip link delete ~a" veth))))

  (run "ip link set br0 down")

  (run "ip link delete br0"))

(format #t "\nCleanup completed.\n")
