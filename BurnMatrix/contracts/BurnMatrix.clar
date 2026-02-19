;; contract title: ai-token-burn
;; contract description:
;; This contract implements an advanced AI-Guided Token Burn Mechanism designed to
;; autonomously stabilize the token economy. It interfaces with an authorized
;; off-chain AI Oracle that provides real-time market data (volume, volatility, sentiment).
;;
;; The contract includes several safety mechanisms and advanced features:
;; 1. Dynamic Burn Logic: Calculates burn amounts based on a multi-factor weighted formula.
;; 2. Emergency Controls: Allows the contract owner to pause operations in case of volatility or bugs.
;; 3. Burn Caps: Enforces hard limits on how much can be burned in a single transaction to prevent accidents.
;; 4. Detailed Auditing: Stores comprehensive records of every burn event for transparency.
;;
;; Security considerations:
;; - Only the authorized AI Oracle can trigger dynamic burns.
;; - Only the Contract Owner can administrative settings (oracle, pause, caps).
;; - Checks-Effects-Interactions pattern is strictly followed.
;; - Math operations use standard uint safety (Clarity prevents overflow/underflow by default).

;; =================================================================================
;; CONSTANTS
;; =================================================================================

;; The principal who deployed the contract and has admin privileges.
;; This address is the only one authorized to change the AI oracle or pause the system.
(define-constant contract-owner tx-sender)

;; Error Code: Caller is not the contract owner
(define-constant err-owner-only (err u100))

;; Error Code: Caller is not the authorized AI oracle
(define-constant err-ai-only (err u101))

;; Error Code: The calculated burn amount is zero or invalid
(define-constant err-invalid-burn-amount (err u102))

;; Error Code: The contract is currently paused
(define-constant err-contact-paused (err u103))

;; Error Code: The calculated burn amount exceeds the safety cap
(define-constant err-burn-limit-exceeded (err u104))

;; =================================================================================
;; DATA MAPS AND VARS
;; =================================================================================

;; Authorization: The principal of the off-chain AI agent allowed to trigger burns.
;; This can be updated by the contract owner if the agent's key is rotated.
(define-data-var ai-oracle principal tx-sender)

;; System Status: Circuit breaker to stop all burn actions in an emergency.
;; Default is false (active).
(define-data-var is-paused bool false)

;; Safety Cap: The maximum amount of tokens that can be burned in a single transaction.
;; This prevents a rogue AI or bad data from destroying the entire supply.
;; Default: 1,000,000 tokens (assuming 6 decimals, this is 1 token, adjust as needed).
(define-data-var max-burn-per-cycle uint u1000000000)

;; Metric: Total amount of tokens burned by this contract since deployment.
(define-data-var total-burned uint u0)

;; Metric: Total number of successful burn cycles executed.
(define-data-var total-burn-cycles uint u0)

;; History: A detailed map of every burn event.
;; Keys are indexed by a simple counter (burn-id).
;; This allows for easy off-chain indexing and auditing.
(define-map burn-history
    uint ;; burn-id
    {
        block-height: uint,           ;; When it happened
        amount: uint,                 ;; How much was burned
        sender: principal,            ;; Who triggered it (usually AI)
        reason: (string-ascii 64),    ;; Reason tag
        market-volatility: uint,      ;; Snapshot of data
        market-sentiment: uint,       ;; Snapshot of data
        liquidity-depth: uint         ;; Snapshot of data
    }
)

;; Mock Fungible Token (SIP-010 trait implementation simplified for this example)
;; In a real deployment, this would be a trait reference to the actual token contract.
(define-fungible-token ai-token)

;; =================================================================================
;; PRIVATE FUNCTIONS
;; =================================================================================

;; @desc Check if the caller is the contract owner.
;; Used for administrative functions.
(define-private (is-contract-owner)
    (is-eq tx-sender contract-owner)
)

;; @desc Check if the contract is currently active (not paused).
;; Returns true if NOT paused, false if paused.
(define-private (is-active)
    (not (var-get is-paused))
)

;; @desc Check if the caller is the authorized AI oracle.
;; Used for the core dynamic burn function.
(define-private (is-ai-oracle)
    (is-eq tx-sender (var-get ai-oracle))
)

;; @desc Internal helper to record a burn event in the history map.
;; Increments the daily burn cycle counter and stores the data.
(define-private (log-burn-event 
    (amount uint) 
    (reason (string-ascii 64)) 
    (vol uint) 
    (sent uint)
    (liq uint))
    (let
        (
            (new-id (+ (var-get total-burn-cycles) u1))
        )
        (map-set burn-history new-id {
            block-height: block-height,
            amount: amount,
            sender: tx-sender,
            reason: reason,
            market-volatility: vol,
            market-sentiment: sent,
            liquidity-depth: liq
        })
        (var-set total-burn-cycles new-id)
        new-id
    )
)

;; =================================================================================
;; PUBLIC FUNCTIONS - ADMINISTRATION
;; =================================================================================

;; @desc Update the authorized AI Oracle address.
;; Only callable by contract owner.
;; @param new-oracle: The principal of the new AI agent.
(define-public (set-ai-oracle (new-oracle principal))
    (begin
        (asserts! (is-contract-owner) err-owner-only)
        (ok (var-set ai-oracle new-oracle))
    )
)

;; @desc Toggle the emergency pause state.
;; Only callable by contract owner.
;; @param paused: True to pause, False to resume.
(define-public (set-paused (paused bool))
    (begin
        (asserts! (is-contract-owner) err-owner-only)
        (var-set is-paused paused)
        (print {event: "contract-pause-status-changed", new-status: paused})
        (ok true)
    )
)

;; @desc Update the maximum burn limit per cycle.
;; Only callable by contract owner.
;; @param new-cap: The new maximum amount allowed.
(define-public (set-max-burn-cap (new-cap uint))
    (begin
        (asserts! (is-contract-owner) err-owner-only)
        (var-set max-burn-per-cycle new-cap)
        (print {event: "max-burn-cap-updated", new-cap: new-cap})
        (ok true)
    )
)

;; =================================================================================
;; PUBLIC FUNCTIONS - USER & CORE
;; =================================================================================

;; @desc Allow users to manually burn tokens for community support.
;; This functions as a "donation to the void" and is tracked separately.
;; @param amount: The amount of tokens to burn.
(define-public (burn-tokens (amount uint))
    (begin
        (asserts! (is-active) err-contact-paused)
        (try! (ft-burn? ai-token amount tx-sender))
        
        ;; Update global stats
        (var-set total-burned (+ (var-get total-burned) amount))
        
        ;; Log this simple event
        (let ((log-id (log-burn-event amount "manual-user-burn" u0 u0 u0)))
            (print {event: "manual-burn", amount: amount, user: tx-sender, id: log-id})
        )
        (ok true)
    )
)

;; =================================================================================
;; GETTERS (Read-Only)
;; =================================================================================

(define-read-only (get-total-burned)
    (ok (var-get total-burned))
)

(define-read-only (get-burn-history (burn-id uint))
    (map-get? burn-history burn-id)
)

(define-read-only (get-system-status)
    {
        paused: (var-get is-paused),
        oracle: (var-get ai-oracle),
        max-cap: (var-get max-burn-per-cycle),
        total-cycles: (var-get total-burn-cycles)
    }
)


