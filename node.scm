(use-modules (gnu))

(operating-system
 (timezone "America/Sao_Paulo")
 (host-name "node")
 (services %base-services)
 (packages (cons* (specification->package "guile-goblins") %base-packages))
 (bootloader (bootloader-configuration
	      (bootloader grub-bootloader)
	      (targets '("/dev/sdX"))))

 (file-systems (cons (file-system
		      (device (file-system-label (string-append "node-fs")))
		      (mount-point "/")
		      (type "ext4"))
		     %base-file-systems)))
