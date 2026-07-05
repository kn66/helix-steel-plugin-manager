(require "helix/static.scm")
(require (prefix-in helix.misc. "helix/misc.scm"))
(require "steel/result")
(require-builtin steel/filesystem)
(require-builtin steel/process)

(provide plugin-root
         plugin-registry-path
         plugin-registry
         plugin-manager-init
         plugin-manager-update
         plugin-ensure
         plugin-list
         plugin-install
         plugin-update
         plugin-remove
         plugin-enable
         plugin-disable
         plugin-load
         plugin-load-all)

(define (path-join . parts)
  (cond
    [(null? parts) ""]
    [(null? (cdr parts)) (car parts)]
    [else
     (let ([left (trim-end-matches (car parts) "/")]
           [right (trim-start-matches (apply path-join (cdr parts)) "/")])
       (string-append left "/" right))]))

(define (config-root)
  (parent-name (get-init-scm-path)))

;;@doc
;; Directory where plugin repositories are cloned.
(define (plugin-root)
  (path-join (config-root) "steel" "plugins"))

;;@doc
;; File where the plugin manager stores installed plugin metadata.
(define (plugin-registry-path)
  (path-join (plugin-root) "registry.scm"))

(define (plugin-manager-installed-path)
  (path-join (config-root) "helix" "plugin-manager.scm"))

(define (plugin-manager-source-path)
  (path-join (config-root) "helix" "plugin-manager-source"))

(define (ensure-plugin-root!)
  (unless (path-exists? (plugin-root))
    (create-directory! (plugin-root))))

(define (file->string path)
  (let ([port (open-input-file path)])
    (let ([contents (read-port-to-string port)])
      (close-port port)
      contents)))

(define (string->file path contents)
  (let ([port (open-output-file path #:exists 'truncate)])
    (display contents port)
    (close-port port)))

(define (make-plugin name source entry branch enabled?)
  (list name source entry branch enabled?))

(define (plugin-name plugin) (list-ref plugin 0))
(define (plugin-source plugin) (list-ref plugin 1))
(define (plugin-entry plugin) (list-ref plugin 2))
(define (plugin-branch plugin) (list-ref plugin 3))
(define (plugin-enabled? plugin) (list-ref plugin 4))

(define (plugin-path name)
  (path-join (plugin-root) name))

;;@doc
;; Return the raw plugin registry as a list.
(define (plugin-registry)
  (let ([registry (plugin-registry-path)])
    (if (path-exists? registry)
        (let ([port (open-input-file registry)])
          (let ([plugins (read port)])
            (close-port port)
            plugins))
        '())))

(define (save-registry! plugins)
  (ensure-plugin-root!)
  (let ([port (open-output-file (plugin-registry-path) #:exists 'truncate)])
    (write plugins port)
    (display "\n" port)
    (close-port port)))

(define (remove-plugin-spec name plugins)
  (cond
    [(null? plugins) '()]
    [(equal? name (plugin-name (car plugins))) (remove-plugin-spec name (cdr plugins))]
    [else (cons (car plugins) (remove-plugin-spec name (cdr plugins)))]))

(define (upsert-plugin-spec plugin plugins)
  (cons plugin (remove-plugin-spec (plugin-name plugin) plugins)))

(define (find-plugin-spec name plugins)
  (cond
    [(null? plugins) #false]
    [(equal? name (plugin-name (car plugins))) (car plugins)]
    [else (find-plugin-spec name (cdr plugins))]))

(define (replace-plugin-spec plugin plugins)
  (upsert-plugin-spec plugin plugins))

(define (valid-plugin-name? name)
  (and (not (equal? name ""))
       (not (string-contains? name "/"))
       (not (string-contains? name "\\"))
       (not (string-contains? name ":"))
       (not (string-contains? name ".."))))

(define (assert-valid-plugin-name! name)
  (unless (valid-plugin-name? name)
    (error (string-append "invalid plugin name: " name))))

(define (last-item items)
  (if (null? (cdr items))
      (car items)
      (last-item (cdr items))))

(define (strip-url-suffixes source)
  (let* ([no-query (car (split-many source "?"))]
         [no-fragment (car (split-many no-query "#"))])
    (trim-end-matches no-fragment "/")))

(define (derive-plugin-name source)
  (let* ([cleaned (strip-url-suffixes source)]
         [last-path-part (last-item (split-many cleaned "/"))]
         [last-scp-part (last-item (split-many last-path-part ":"))]
         [name (trim-end-matches last-scp-part ".git")])
    (assert-valid-plugin-name! name)
    name))

(define (github-shorthand? source)
  (and (not (string-contains? source "://"))
       (not (starts-with? source "git@"))
       (= (length (split-many source "/")) 2)))

(define (normalize-source source)
  (if (github-shorthand? source)
      (string-append "https://github.com/" source ".git")
      source))

(define (scheme-quote-string value)
  (string-append "\""
                 (string-replace
                   (string-replace value "\\" "\\\\")
                   "\""
                   "\\\"")
                 "\""))

(define (run-command program args cwd)
  (ensure-plugin-root!)
  (let* ([stdout-path (path-join (plugin-root) ".last-command.stdout")]
         [stderr-path (path-join (plugin-root) ".last-command.stderr")]
         [builder (command program args)])
    (when cwd (with-current-dir builder cwd))
    (with-stdout builder (open-output-file stdout-path #:exists 'truncate))
    (with-stderr builder (open-output-file stderr-path #:exists 'truncate))
    (let* ([child (unwrap-ok (spawn-process builder))]
           [status (unwrap-ok (wait child))]
           [stdout (file->string stdout-path)]
           [stderr (file->string stderr-path)])
      (if (equal? status 0)
          stdout
          (error
            (string-append program
                           " failed with status "
                           (to-string status)
                           "\n"
                           stdout
                           stderr))))))

(define (run-git args cwd)
  (run-command "git" args cwd))

(define (plugin-update-action action)
  (let ([value (if action (string-downcase (trim (to-string action))) "")])
    (cond
      [(or (equal? value "") (equal? value "ask")) "ask"]
      [(or (equal? value "y") (equal? value "yes")
           (equal? value "discard") (equal? value "force") (equal? value "reset")) "discard"]
      [(or (equal? value "n") (equal? value "no")
           (equal? value "cancel") (equal? value "skip") (equal? value "keep")) "cancel"]
      [else
       (error
         (string-append
           "unknown plugin update action: "
           value
           ". Use ask, y, or n"))])))

(define (plugin-directory plugin)
  (plugin-path (plugin-name plugin)))

(define (plugin-manager-source-directory)
  (let ([source-path (plugin-manager-source-path)])
    (if (path-exists? source-path)
        (trim (file->string source-path))
        (parent-name (plugin-manager-installed-path)))))

(define (ensure-plugin-directory! directory)
  (unless (path-exists? directory)
    (error (string-append "plugin directory not found: " directory))))

(define (plugin-local-changes directory)
  (run-git (list "status" "--porcelain") directory))

(define (plugin-local-changes? directory)
  (not (equal? (plugin-local-changes directory) "")))

(define (dirty-plugins plugins)
  (filter
    (lambda (plugin)
      (let ([directory (plugin-directory plugin)])
        (ensure-plugin-directory! directory)
        (plugin-local-changes? directory)))
    plugins))

(define (discard-plugin-local-changes! directory)
  (run-git (list "reset" "--hard") directory)
  (run-git (list "clean" "-fd") directory))

(define (plugin-update-local-changes-message dirty)
  (let ([names (string-join (map plugin-name dirty) ", ")])
    (if (= (length dirty) 1)
        (string-append
          "local changes in "
          names
          "; run :plugin-update "
          (plugin-name (car dirty))
          " discard to reset them before updating")
        (string-append
          "local changes in "
          names
          "; update each dirty plugin with :plugin-update <name> discard"))))

(define (candidate-entries name)
  (list "helix.scm" "init.scm" "plugin.scm" "cog.scm" (string-append name ".scm")))

(define (first-existing-entry plugin-directory entries)
  (cond
    [(null? entries) #false]
    [(path-exists? (path-join plugin-directory (car entries))) (car entries)]
    [else (first-existing-entry plugin-directory (cdr entries))]))

(define (resolve-entry plugin-directory requested-entry name)
  (cond
    [requested-entry
     (if (path-exists? (path-join plugin-directory requested-entry))
         requested-entry
         (error (string-append "plugin entry not found: " requested-entry)))]
    [else
     (let ([entry (first-existing-entry plugin-directory (candidate-entries name))])
       (if entry
           entry
           (error
             (string-append
               "plugin entry not found. Expected helix.scm, init.scm, plugin.scm, cog.scm, or "
               name
               ".scm"))))]))

(define (resolve-existing-entry plugin-directory plugin requested-entry)
  (cond
    [requested-entry
     (resolve-entry plugin-directory requested-entry (plugin-name plugin))]
    [(path-exists? (path-join plugin-directory (plugin-entry plugin)))
     (plugin-entry plugin)]
    [else
     (resolve-entry plugin-directory #false (plugin-name plugin))]))

(define (load-plugin-spec plugin)
  (let* ([entry-path (path-join (plugin-path (plugin-name plugin)) (plugin-entry plugin))]
         [require-expression (string-append "(require " (scheme-quote-string entry-path) ")")])
    (unless (path-exists? entry-path)
      (error (string-append "plugin entry not found: " entry-path)))
    (eval-string require-expression)
    (string-append "loaded " (plugin-name plugin))))

(define (install-existing-plugin plugin target entry branch)
  (let ([resolved-entry (resolve-existing-entry target plugin entry)])
    (when (and branch (not (equal? branch (plugin-branch plugin))))
      (error
        (string-append
          "plugin already installed with a different branch: "
          (plugin-name plugin))))
    (let ([updated (make-plugin (plugin-name plugin)
                                (plugin-source plugin)
                                resolved-entry
                                (plugin-branch plugin)
                                #true)])
      (save-registry! (replace-plugin-spec updated (plugin-registry)))
      (load-plugin-spec updated)
      (string-append "already installed " (plugin-name plugin)))))

;;@doc
;; Clone a plugin repository and load its entry file.
;;
;; `source` can be a full git URL or a GitHub shorthand such as "owner/repo".
;; `name`, `entry`, and `branch` are optional. The entry defaults to the first
;; existing file from helix.scm, init.scm, plugin.scm, cog.scm, or <name>.scm.
(define (plugin-install source [name #false] [entry #false] [branch #false])
  (let* ([url (normalize-source source)]
         [plugin-name (or name (derive-plugin-name source))]
         [target (plugin-path plugin-name)]
         [plugins (plugin-registry)]
         [existing (find-plugin-spec plugin-name plugins)])
    (assert-valid-plugin-name! plugin-name)
    (ensure-plugin-root!)
    (cond
      [existing
       (unless (equal? url (plugin-source existing))
         (error
           (string-append
             "plugin already installed with a different source: "
             plugin-name)))
       (if (path-exists? target)
           (install-existing-plugin existing target entry branch)
           (begin
             (run-git
               (append (list "clone")
                       (if (or branch (plugin-branch existing))
                           (list "--branch" (or branch (plugin-branch existing)))
                           '())
                       (list url target))
               #false)
             (install-existing-plugin existing target entry branch)))]
      [(path-exists? target)
       (let* ([resolved-entry (resolve-entry target entry plugin-name)]
              [plugin (make-plugin plugin-name url resolved-entry branch #true)])
         (save-registry! (upsert-plugin-spec plugin plugins))
         (load-plugin-spec plugin)
         (string-append "registered existing " plugin-name))]
      [else
       (run-git
         (append (list "clone")
                 (if branch (list "--branch" branch) '())
                 (list url target))
         #false)
       (let* ([resolved-entry (resolve-entry target entry plugin-name)]
              [plugin (make-plugin plugin-name url resolved-entry branch #true)])
         (save-registry! (upsert-plugin-spec plugin (plugin-registry)))
         (load-plugin-spec plugin)
         (string-append "installed " plugin-name))])))

;;@doc
;; Ensure a plugin is installed and loaded. This is intended for init.scm.
(define (plugin-ensure source [name #false] [entry #false] [branch #false])
  (let ([label (if name name source)])
    (with-handler
      (lambda (err)
        (let ([message (string-append "plugin install skipped: " label ": " (to-string err))])
          (helix.misc.set-warning! message)
          message))
      (plugin-install source name entry branch))))

;;@doc
;; Load enabled plugins. This is the shortest stable entry point for init.scm.
(define (plugin-manager-init)
  (with-handler
    (lambda (err)
      (let ([message (string-append "plugin-manager init failed: " (to-string err))])
        (helix.misc.set-warning! message)
        message))
    (plugin-load-all)))

;;@doc
;; Update the plugin manager repository and refresh a copy-based install.
(define (plugin-manager-update [dirty-action "ask"])
  (let* ([source-directory (plugin-manager-source-directory)]
         [source-file (path-join source-directory "plugin-manager.scm")]
         [target-file (plugin-manager-installed-path)]
         [action (plugin-update-action dirty-action)])
    (unless (path-exists? (path-join source-directory ".git"))
      (error
        (string-append
          "plugin manager source is not a git checkout: "
          source-directory)))
    (unless (path-exists? source-file)
      (error (string-append "plugin-manager.scm not found: " source-file)))
    (if (and (plugin-local-changes? source-directory)
             (not (equal? action "discard")))
        (if (equal? action "ask")
            "plugin manager has local changes; run :plugin-manager-update discard to reset them"
            "skipped plugin manager update (local changes kept)")
        (begin
          (when (equal? action "discard")
            (discard-plugin-local-changes! source-directory))
          (run-git (list "pull" "--ff-only") source-directory)
          (when (not (equal? (file->string source-file) (file->string target-file)))
            (string->file target-file (file->string source-file)))
          (string-append
            "updated plugin manager from "
            source-directory
            "; restart Helix or reload Steel configuration to use new definitions")))))

(define (update-plugin-spec plugin [dirty-action "ask"])
  (let* ([directory (plugin-directory plugin)]
         [action (plugin-update-action dirty-action)])
    (ensure-plugin-directory! directory)
    (if (plugin-local-changes? directory)
        (cond
          [(equal? action "discard")
           (discard-plugin-local-changes! directory)
           (run-git (list "pull" "--ff-only") directory)
           (string-append "discarded local changes and updated " (plugin-name plugin))]
          [(equal? action "cancel")
           (string-append "skipped " (plugin-name plugin) " (local changes kept)")]
          [else
           (plugin-update-local-changes-message (list plugin))])
        (begin
          (run-git (list "pull" "--ff-only") directory)
          (string-append "updated " (plugin-name plugin))))))

(define (update-plugins plugins [dirty-action "ask"])
  (string-join
    (map (lambda (plugin) (update-plugin-spec plugin dirty-action)) plugins)
    "\n"))

;;@doc
;; Update one plugin by name, or every installed plugin when no name is given.
(define (plugin-update [name #false] [dirty-action "ask"])
  (let* ([plugins (plugin-registry)]
         [action (plugin-update-action dirty-action)])
    (if name
        (let ([plugin (find-plugin-spec name plugins)])
          (unless plugin (error (string-append "unknown plugin: " name)))
          (update-plugin-spec plugin action))
        (if (null? plugins)
            "No plugins installed"
            (let ([dirty (dirty-plugins plugins)])
              (if (and (equal? action "ask") (not (null? dirty)))
                  (plugin-update-local-changes-message dirty)
                  (update-plugins plugins action)))))))

;;@doc
;; Remove a plugin from the registry. By default, the cloned repository is also deleted.
(define (plugin-remove name [delete-files? #true])
  (let* ([plugins (plugin-registry)]
         [plugin (find-plugin-spec name plugins)])
    (unless plugin (error (string-append "unknown plugin: " name)))
    (when (and delete-files? (path-exists? (plugin-path name)))
      (delete-directory! (plugin-path name)))
    (save-registry! (remove-plugin-spec name plugins))
    (string-append "removed " name)))

(define (set-plugin-enabled! name enabled?)
  (let* ([plugins (plugin-registry)]
         [plugin (find-plugin-spec name plugins)])
    (unless plugin (error (string-append "unknown plugin: " name)))
    (let ([updated (make-plugin (plugin-name plugin)
                                (plugin-source plugin)
                                (plugin-entry plugin)
                                (plugin-branch plugin)
                                enabled?)])
      (save-registry! (replace-plugin-spec updated plugins))
      updated)))

;;@doc
;; Enable a plugin for future `plugin-load-all` calls.
(define (plugin-enable name)
  (let ([plugin (set-plugin-enabled! name #true)])
    (load-plugin-spec plugin)
    (string-append "enabled " name)))

;;@doc
;; Disable a plugin for future `plugin-load-all` calls. This does not unload code
;; already evaluated in the current Steel engine.
(define (plugin-disable name)
  (set-plugin-enabled! name #false)
  (string-append "disabled " name))

;;@doc
;; Load one installed plugin by name.
(define (plugin-load name)
  (let ([plugin (find-plugin-spec name (plugin-registry))])
    (unless plugin (error (string-append "unknown plugin: " name)))
    (load-plugin-spec plugin)))

(define (load-enabled plugins)
  (cond
    [(null? plugins) '()]
    [(plugin-enabled? (car plugins))
     (cons (load-plugin-spec (car plugins)) (load-enabled (cdr plugins)))]
    [else (load-enabled (cdr plugins))]))

;;@doc
;; Load every enabled plugin from the registry. Put this in init.scm for startup loading.
(define (plugin-load-all)
  (let ([loaded (load-enabled (plugin-registry))])
    (if (null? loaded)
        "No enabled plugins"
        (string-join loaded "\n"))))

(define (plugin->line plugin)
  (string-append (plugin-name plugin)
                 " ["
                 (if (plugin-enabled? plugin) "enabled" "disabled")
                 "] "
                 (plugin-source plugin)
                 " -> "
                 (plugin-entry plugin)))

;;@doc
;; Show installed plugins.
(define (plugin-list)
  (let ([plugins (plugin-registry)])
    (if (null? plugins)
        "No plugins installed"
        (string-join (map plugin->line plugins) "\n"))))
