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

;; @desc Execute an Advanced Dynamic Burn Cycle.
;; This function is the core of the AI-driven mechanism. It accepts data points
;; regarding the market verified by the oracle and computes a burn amount.
;;
;; The algorithm works in multiple stages:
;; 1. Base Rate: Derived from 24h volume.
;; 2. Volatility Adjustment: Amplifies burn in high volatility to signal stability.
;; 3. Sentiment Adjustment: Increases burn in bearish markets to reduce supply pressure.
;; 4. Liquidity Safety: Dampens the burn if liquidity depth is too low to prevent slippage shocks.
;;
;; @param volatility-index: 0-100 scale representing market volatility (VIX style).
;; @param sentiment-score: 0-100 scale (<50 bearish, >50 bullish).
;; @param volume-24h: The 24h trading volume (in token units).
;; @param liquidity-depth: A score or amount representing market depth (0-1000 scale).
;; @param moving-average-price: The 7-day moving average price (scaled).
(define-public (execute-dynamic-burn-cycle 
    (volatility-index uint) 
    (sentiment-score uint) 
    (volume-24h uint)
    (liquidity-depth uint)
    (moving-average-price uint))
    (let
        (
            ;; ---------------------------------------------------------------------
            ;; Step 1: Validation & Authorization
            ;; ---------------------------------------------------------------------
            ;; Ensure the system is running and the caller is authorized.
            (check-active (asserts! (is-active) err-contact-paused))
            (check-auth (asserts! (is-ai-oracle) err-ai-only))

            ;; ---------------------------------------------------------------------
            ;; Step 2: Base Calculation
            ;; ---------------------------------------------------------------------
            ;; Start with a conservative base rate of 0.05% of the 24h volume.
            ;; Logic: Higher volume supports higher burns without impacting liquidity.
            (base-rate-bps u5) ;; 5 basis points (0.05%)
            (base-burn (/ (* volume-24h base-rate-bps) u10000))

            ;; ---------------------------------------------------------------------
            ;; Step 3: Volatility Multiplier
            ;; ---------------------------------------------------------------------
            ;; High volatility (> 75) indicates market uncertainty.
            ;; We double the burn rate to signal protocol confidence and reduce float.
            ;; Moderate volatility (40-75) gets a 1.5x multiplier.
            ;; Low volatility (< 40) keeps the standard 1.0x rate.
            (volatility-mult 
                (if (> volatility-index u75) 
                    u200 ;; 2.00x
                    (if (> volatility-index u40)
                        u150 ;; 1.50x
                        u100 ;; 1.00x
                    )
                )
            )

            ;; ---------------------------------------------------------------------
            ;; Step 4: Sentiment Adjustment
            ;; ---------------------------------------------------------------------
            ;; Bearish sentiment (< 40) suggests selling pressure.
            ;; We increase burn by 20% to counteract supply inflation.
            ;; Neutral sentiment (40-60) gets no change.
            ;; Bullish sentiment (> 60) reduces burn by 10% (market checks itself).
            (sentiment-factor
                (if (< sentiment-score u40)
                    u120 ;; 1.20x (Bearish boost)
                    (if (> sentiment-score u60)
                        u90  ;; 0.90x (Bullish taper)
                        u100 ;; 1.00x (Neutral)
                    )
                )
            )

            ;; ---------------------------------------------------------------------
            ;; Step 5: Liquidity Dampener (Safety Mechanism)
            ;; ---------------------------------------------------------------------
            ;; If liquidity depth is low (< 200 on our scale), strictly reduce the burn.
            ;; We do not want to burn tokens if the market is too thin.
            ;; If depth < 200, multiplier is 0.5x. Otherwise 1.0x.
            (liquidity-dampener
                (if (< liquidity-depth u200)
                    u50  ;; 0.50x
                    u100 ;; 1.00x
                )
            )

            ;; ---------------------------------------------------------------------
            ;; Step 6: Final Amount Aggregation
            ;; ---------------------------------------------------------------------
            ;; Formula: Base * Volatility * Sentiment * Liquidity / (Scaling Factors)
            ;; Note: We have 3 multipliers scaled by 100 each.
            ;; Denominator = 100 * 100 * 100 = 1,000,000
            (raw-burn-amount 
                (/ 
                    (* (* (* base-burn volatility-mult) sentiment-factor) liquidity-dampener) 
                    u1000000
                )
            )
        )

        ;; -------------------------------------------------------------------------
        ;; Step 7: Final Validations
        ;; -------------------------------------------------------------------------
        
        ;; Ensure we aren't burning nothing
        (asserts! (> raw-burn-amount u0) err-invalid-burn-amount)

        ;; Ensure we don't exceed the safety cap per cycle
        (asserts! (<= raw-burn-amount (var-get max-burn-per-cycle)) err-burn-limit-exceeded)

        ;; -------------------------------------------------------------------------
        ;; Step 8: Execution
        ;; -------------------------------------------------------------------------
        ;; Burn the tokens from the AI Agent's wallet (tx-sender)
        (try! (ft-burn? ai-token raw-burn-amount tx-sender))

        ;; Update global total
        (var-set total-burned (+ (var-get total-burned) raw-burn-amount))

        ;; Log to history
        (log-burn-event 
            raw-burn-amount 
            "ai-dynamic-burn-v2" 
            volatility-index 
            sentiment-score 
            liquidity-depth
        )

        ;; Emit detailed telemetry event
        (print {
            action: "dynamic-burn-v2-complete",
            burn-amount: raw-burn-amount,
            inputs: {
                vol: volatility-index,
                sent: sentiment-score,
                liq: liquidity-depth,
                vol-24h: volume-24h,
                ma-price: moving-average-price
            },
            multipliers: {
                vol-mult: volatility-mult,
                sent-fact: sentiment-factor,
                liq-damp: liquidity-dampener
            }
        })

        ;; -------------------------------------------------------------------------
        ;; Step 9: Return
        ;; -------------------------------------------------------------------------
        ;; Return a success tuple with the new state
        (ok {
            burned: raw-burn-amount,
            new-total-burned: (var-get total-burned),
            cap-remaining: (- (var-get max-burn-per-cycle) raw-burn-amount),
            status: "optimized-burn-executed"
        })
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


