#!/usr/bin/env bash
# emacs_setup.sh --- Unified setup, testing, and verification suite for Emacs
#
# Usage:
#   ./emacs_setup.sh [COMMAND / SCOPED_STAGE] [OPTIONS]
#
# Default Behavior:
#   Running without arguments executes the complete 7-stage sequence:
#   checks local-config, tangles README.org, validates Elisp syntax, runs
#   headless boot smoke test, checks Elpaca package builds, evaluates all active
#   modules, and emulates interactive startup hooks.
#
# Commands & Scoped Parameters:
#   clean, --clean      Delete generated tangle artifacts (early-init.el, init.el, lisp/) and eln-cache/
#   --tangle            Only tangle README.org literate configuration
#   --compile           Only run byte-compile syntax & macro validation
#   --smoke             Only run headless boot smoke test
#   --queues            Only verify Elpaca queues and package build statuses
#   --modules           Only verify active module loading and :config evaluation
#   --hooks             Only verify after-init-hook and interactive boot emulation
#   --all, --verify     Explicitly execute all 7 stages (same as default)
#
# Options:
#   --copy              Copy template-local-config.org instead of symlinking
#   --nw                Launch Emacs in terminal mode upon success
#   --gui               Launch Emacs in graphical mode upon success
#   --help, -h          Show this help message
#
# Log File:
#   Detailed execution and error logs are stored in emacs_setup.log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_FILE="${SCRIPT_DIR}/emacs_setup.log"

MODE=""
DO_CLEAN=false
COPY_TEMPLATE=false
LAUNCH_MODE=""

for arg in "$@"; do
  case "$arg" in
    clean|--clean)
      DO_CLEAN=true
      ;;
    --all|--verify|--test|-v)
      MODE="all"
      ;;
    --tangle)
      MODE="tangle"
      ;;
    --compile)
      MODE="compile"
      ;;
    --smoke)
      MODE="smoke"
      ;;
    --queues)
      MODE="queues"
      ;;
    --modules)
      MODE="modules"
      ;;
    --hooks)
      MODE="hooks"
      ;;
    --copy)
      COPY_TEMPLATE=true
      ;;
    --nw)
      LAUNCH_MODE="-nw"
      ;;
    --gui)
      LAUNCH_MODE="gui"
      ;;
    --help|-h)
      echo "Usage: ./emacs_setup.sh [COMMAND / SCOPED_STAGE] [OPTIONS]"
      echo ""
      echo "Default:"
      echo "  (no args)           Runs complete 7-stage sequence (setup, tangle, test, verify)"
      echo ""
      echo "Commands / Scoped Parameters:"
      echo "  clean, --clean      Delete generated tangle artifacts (early-init.el, init.el, lisp/) and eln-cache/"
      echo "  --tangle            Only tangle literate configuration from README.org"
      echo "  --compile           Only byte-compile lisp/*.el for syntax validation"
      echo "  --smoke             Only run headless boot smoke test"
      echo "  --queues            Only check Elpaca queue and package compile statuses"
      echo "  --modules           Only evaluate active modules and package configs"
      echo "  --hooks             Only emulate after-init-hook startup sequence"
      echo "  --all, --verify     Explicitly run all 7 stages (same as default)"
      echo ""
      echo "Options:"
      echo "  --copy              Copy template-local-config.org instead of symlinking"
      echo "  --nw                Launch Emacs in terminal mode upon success"
      echo "  --gui               Launch Emacs in GUI mode upon success"
      echo ""
      echo "Log File:"
      echo "  All outputs and diagnostics are saved to emacs_setup.log"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Run './emacs_setup.sh --help' for usage." >&2
      exit 1
      ;;
  esac
done

if [[ "$DO_CLEAN" == true && -z "$MODE" ]]; then
  MODE="clean"
elif [[ -z "$MODE" ]]; then
  MODE="all"
fi

if ! command -v emacs >/dev/null 2>&1; then
  echo "Error: 'emacs' executable not found in PATH." >&2
  exit 1
fi

# Initialize log file
{
  echo "============================================================"
  echo " Emacs Setup & Verification Log"
  echo " Timestamp: $(date -Iseconds)"
  echo " Mode:      $MODE (clean=$DO_CLEAN)"
  echo " Directory: $SCRIPT_DIR"
  echo " Emacs:     $(command -v emacs) ($(emacs --version | head -n 1))"
  echo "============================================================"
  echo ""
} > "$LOG_FILE"

# -----------------------------------------------------------------------------
# Stage Definitions
# -----------------------------------------------------------------------------

stage_clean() {
  echo "--> [Action: Clean] Deleting generated tangle artifacts and cached compilations..."
  local deleted=()

  if [[ -f "early-init.el" ]]; then
    rm -f "early-init.el"
    deleted+=("early-init.el")
  fi
  if [[ -f "init.el" ]]; then
    rm -f "init.el"
    deleted+=("init.el")
  fi
  if [[ -d "lisp" ]]; then
    rm -rf "lisp"
    deleted+=("lisp/")
  fi
  if compgen -G "*.elc" >/dev/null; then
    rm -f *.elc
    deleted+=("*.elc")
  fi
  if [[ -d "eln-cache" ]]; then
    rm -rf "eln-cache"
    deleted+=("eln-cache/")
  fi

  if [[ ${#deleted[@]} -gt 0 ]]; then
    echo "    Cleaned: ${deleted[*]}"
  else
    echo "    Nothing to clean (already clean)."
  fi
}

stage_local_config() {
  echo "--> [Stage 1/7: Local Config] Checking local-config.org..."
  if [[ ! -e "local-config.org" ]]; then
    if [[ ! -f "template-local-config.org" ]]; then
      echo "Error: template-local-config.org not found in $SCRIPT_DIR!" >&2
      return 1
    fi
    if [[ "$COPY_TEMPLATE" == true ]]; then
      echo "    Creating local-config.org by copying template-local-config.org..."
      cp template-local-config.org local-config.org
    else
      echo "    Creating local-config.org by symlinking template-local-config.org..."
      ln -s template-local-config.org local-config.org
    fi
  else
    echo "    local-config.org already exists. Leaving intact."
  fi
}

stage_tangle() {
  echo "--> [Stage 2/7: Tangle] Tangling README.org literate configuration..."
  emacs --batch --quick \
    --eval "(require 'org)" \
    --eval "(require 'ox)" \
    --eval '(setq org-confirm-babel-evaluate nil)' \
    --eval "(setq org-babel-pre-tangle-hook (list #'org-export-expand-include-keyword (lambda () (set-buffer-modified-p nil))))" \
    --eval '(org-babel-tangle-file "README.org")'
}

stage_compile() {
  echo "--> [Stage 3/7: Byte-Compile] Checking syntax and macro-expansion in lisp/*.el..."
  local status=0
  emacs --batch --quick \
    --eval '(setq byte-compile-error-on-warn nil)' \
    --eval '(add-to-list (quote load-path) (expand-file-name "lisp"))' \
    --eval '(batch-byte-compile)' lisp/*.el || status=$?
  rm -f lisp/*.elc
  if [[ $status -ne 0 ]]; then
    echo "Error: Byte-compilation failed with exit code $status" >&2
    return $status
  fi
  echo "    Syntax & macro validation passed (temporary .elc cleaned up)."
}

stage_smoke() {
  echo "--> [Stage 4/7: Smoke Test] Testing headless boot through early-init.el and init.el..."
  timeout 20s emacs --batch \
    --load early-init.el \
    --load init.el \
    --eval '(message "    Emacs booted cleanly in %s" (emacs-init-time))'
}

stage_queues() {
  echo "--> [Stage 5/7: Elpaca Queues] Processing package queues and verifying build statuses..."
  timeout 45s emacs --batch \
    --load early-init.el \
    --load init.el \
    --eval '(progn
              (elpaca-process-queues)
              (elpaca-wait)
              (let ((failures (cl-loop for (id . e) in (elpaca--queued)
                                       when (eq (elpaca<-status e) (quote failed))
                                       collect (cons id (cl-loop for event in (reverse (elpaca-event-log id))
                                                                for payload = (elpaca-event<-payload event)
                                                                thereis (or (plist-get payload :info)
                                                                            (plist-get payload :output)))))))
                (if failures
                    (progn
                      (message "ELPACA LOG VERIFICATION FAILED (%d packages failed):" (length failures))
                      (dolist (f failures)
                        (message "  FAIL [%s]: %s" (car f) (cdr f)))
                      (kill-emacs 1))
                  (message "    Elpaca queues processed cleanly: 0 failures."))))'
}

stage_modules() {
  echo "--> [Stage 6/7: Module Activation] Evaluating all active modules and package configs..."
  timeout 60s emacs --batch \
    --load early-init.el \
    --load init.el \
    --eval '(progn
              (elpaca-process-queues)
              (elpaca-wait)
              (dolist (mod active-modules)
                (require mod))
              (message "    All active modules and package configs evaluated successfully."))'
}

stage_hooks() {
  echo "--> [Stage 7/7: Startup Hooks] Emulating after-init-hook interactive boot sequence..."
  timeout 30s emacs --batch \
    --load early-init.el \
    --load init.el \
    --eval '(progn
              (run-hooks (quote after-init-hook))
              (elpaca-wait)
              (message "    Startup hooks and after-init lifecycle executed cleanly in %s." (emacs-init-time)))'
}

# -----------------------------------------------------------------------------
# Execution Driver
# -----------------------------------------------------------------------------

run_flow() {
  set -euo pipefail

  if [[ "$DO_CLEAN" == true && "$MODE" != "clean" ]]; then
    stage_clean
  fi

  case "$MODE" in
    clean)
      echo "============================================================"
      echo " Cleaning Generated Artifacts & Compilation Cache"
      echo " Mode:      clean"
      echo " Log File:  $LOG_FILE"
      echo "============================================================"
      stage_clean
      ;;

    all)
      echo "============================================================"
      echo " Running Complete Emacs Setup & Verification (7 Stages)"
      echo " Mode:      all (default)"
      echo " Log File:  $LOG_FILE"
      echo "============================================================"
      stage_local_config
      stage_tangle
      stage_compile
      stage_smoke
      stage_queues
      stage_modules
      stage_hooks
      ;;

    tangle)
      echo "==> [Scoped Feedback] Running Tangle only..."
      stage_local_config
      stage_tangle
      ;;

    compile)
      echo "==> [Scoped Feedback] Running Byte-Compile syntax validation only..."
      stage_compile
      ;;

    smoke)
      echo "==> [Scoped Feedback] Running Smoke Test only..."
      stage_smoke
      ;;

    queues)
      echo "==> [Scoped Feedback] Running Elpaca Queue verification only..."
      stage_queues
      ;;

    modules)
      echo "==> [Scoped Feedback] Running Module Evaluation only..."
      stage_modules
      ;;

    hooks)
      echo "==> [Scoped Feedback] Running Startup Hook emulation only..."
      stage_hooks
      ;;
  esac
}

# Execute pipeline capturing stdout and stderr into log while showing live output
set +e
run_flow 2>&1 | tee -a "$LOG_FILE"
FLOW_STATUS="${PIPESTATUS[0]}"
set -e

if [[ "$FLOW_STATUS" -ne 0 ]]; then
  echo "" | tee -a "$LOG_FILE"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" | tee -a "$LOG_FILE"
  echo " FAILED: Execution failed in mode '$MODE' (exit code: $FLOW_STATUS)!" | tee -a "$LOG_FILE"
  echo " Check the detailed log file for troubleshooting:" | tee -a "$LOG_FILE"
  echo "   $LOG_FILE" | tee -a "$LOG_FILE"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" | tee -a "$LOG_FILE"
  exit "$FLOW_STATUS"
fi

echo "" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"
if [[ "$MODE" == "all" ]]; then
  echo " SUCCESS: All 7 verification stages passed cleanly!" | tee -a "$LOG_FILE"
elif [[ "$MODE" == "clean" ]]; then
  echo " SUCCESS: Clean completed successfully!" | tee -a "$LOG_FILE"
else
  echo " SUCCESS: Scoped operation '$MODE' completed cleanly!" | tee -a "$LOG_FILE"
fi
echo " Log saved to: $LOG_FILE" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

if [[ "$LAUNCH_MODE" == "-nw" ]]; then
  echo "Launching Emacs in terminal mode..."
  exec emacs -nw
elif [[ "$LAUNCH_MODE" == "gui" ]]; then
  echo "Launching Emacs in GUI mode..."
  exec emacs
fi
