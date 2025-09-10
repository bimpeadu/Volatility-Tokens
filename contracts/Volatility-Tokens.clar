;; Comprehensive Volatility Token Contract
;; Advanced token whose value increases with BTC volatility, includes staking, rewards, and governance

(define-fungible-token volatility-token)

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_BALANCE (err u101))
(define-constant ERR_INVALID_AMOUNT (err u102))
(define-constant ERR_ALREADY_STAKED (err u103))
(define-constant ERR_NOT_STAKED (err u104))
(define-constant ERR_COOLDOWN_ACTIVE (err u105))
(define-constant ERR_ORACLE_STALE (err u106))
(define-constant ERR_EMERGENCY_PAUSED (err u107))

(define-constant VOLATILITY_DECAY_RATE u990000)
(define-constant MIN_VOLATILITY_THRESHOLD u10000)
(define-constant MAX_VOLATILITY_CAP u5000000)
(define-constant ORACLE_FRESHNESS_WINDOW u144)
(define-constant REWARD_RATE u50000)
(define-constant UNSTAKE_COOLDOWN u1008)

(define-data-var total-supply uint u0)
(define-data-var btc-price uint u50000)
(define-data-var previous-btc-price uint u50000)
(define-data-var volatility-multiplier uint u1000000)
(define-data-var current-volatility uint u0)
(define-data-var volatility-index uint u1000000)
(define-data-var last-price-update uint u0)
(define-data-var total-staked uint u0)
(define-data-var reward-pool uint u0)
(define-data-var emergency-pause bool false)
(define-data-var governance-threshold uint u100000000)

(define-map token-balances principal uint)
(define-map staked-balances principal {amount: uint, stake-height: uint, last-claim: uint})
(define-map price-history uint {price: uint, volatility: uint, timestamp: uint})
(define-map governance-proposals uint {proposer: principal, description: (string-ascii 256), votes-for: uint, votes-against: uint, executed: bool})
(define-map user-votes {proposal-id: uint, voter: principal} bool)
(define-map oracle-operators principal bool)
(define-map unstake-requests principal uint)

(define-read-only (get-balance (account principal))
  (default-to u0 (map-get? token-balances account)))

(define-read-only (get-total-supply)
  (var-get total-supply))

(define-read-only (get-current-btc-price)
  (var-get btc-price))

(define-read-only (get-volatility-multiplier)
  (var-get volatility-multiplier))

(define-read-only (get-staked-balance (account principal))
  (default-to {amount: u0, stake-height: u0, last-claim: u0} 
    (map-get? staked-balances account)))

(define-read-only (get-price-history (height uint))
  (map-get? price-history height))

(define-read-only (is-oracle-operator (account principal))
  (default-to false (map-get? oracle-operators account)))

(define-read-only (get-governance-proposal (proposal-id uint))
  (map-get? governance-proposals proposal-id))

(define-read-only (calculate-volatility)
  (let ((current-price (var-get btc-price))
        (prev-price (var-get previous-btc-price)))
    (if (> current-price prev-price)
        (/ (* (- current-price prev-price) u1000000) prev-price)
        (/ (* (- prev-price current-price) u1000000) prev-price))))
(define-read-only (calculate-volatility-index)
  (let ((vol (calculate-volatility))
        (current-index (var-get volatility-index))
        (new-index (+ current-index (if (> vol MIN_VOLATILITY_THRESHOLD) vol MIN_VOLATILITY_THRESHOLD))))
    (if (> new-index MAX_VOLATILITY_CAP) 
        MAX_VOLATILITY_CAP 
        new-index)))

(define-read-only (calculate-rewards (staker principal))
  (let ((stake-info (get-staked-balance staker))
        (staked-amount (get amount stake-info))
        (last-claim (get last-claim stake-info))
        (blocks-staked (- block-height last-claim))
        (volatility-bonus (/ (var-get current-volatility) u10000)))
    (if (> staked-amount u0)
        (/ (* (* staked-amount REWARD_RATE) (+ u1000000 volatility-bonus) blocks-staked) u1000000000000)
        u0)))

(define-read-only (is-oracle-data-fresh)
  (< (- block-height (var-get last-price-update)) ORACLE_FRESHNESS_WINDOW))

(define-public (mint-tokens (amount uint) (recipient principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (try! (ft-mint? volatility-token amount recipient))
    (map-set token-balances recipient 
      (+ (get-balance recipient) amount))
    (var-set total-supply (+ (var-get total-supply) amount))
    (ok true)))

(define-public (transfer (amount uint) (sender principal) (recipient principal))
  (begin
    (asserts! (is-eq tx-sender sender) ERR_UNAUTHORIZED)
    (asserts! (>= (get-balance sender) amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (try! (ft-transfer? volatility-token amount sender recipient))
    (map-set token-balances sender 
      (- (get-balance sender) amount))
    (map-set token-balances recipient 
      (+ (get-balance recipient) amount))
    (ok true)))

(define-public (update-btc-price (new-price uint))
  (begin
    (asserts! (or (is-eq tx-sender CONTRACT_OWNER) 
                  (is-oracle-operator tx-sender)) ERR_UNAUTHORIZED)
    (asserts! (not (var-get emergency-pause)) ERR_EMERGENCY_PAUSED)
    (asserts! (> new-price u0) ERR_INVALID_AMOUNT)
    (var-set previous-btc-price (var-get btc-price))
    (var-set btc-price new-price)
    (var-set last-price-update block-height)
    (let ((volatility (calculate-volatility))
          (decayed-multiplier (/ (* (var-get volatility-multiplier) VOLATILITY_DECAY_RATE) u1000000)))
      (var-set current-volatility volatility)
      (var-set volatility-multiplier 
        (+ decayed-multiplier volatility))
      (var-set volatility-index (calculate-volatility-index))
      (map-set price-history block-height 
        {price: new-price, volatility: volatility, timestamp: block-height})
      (ok volatility))))

(define-public (decay-volatility)
  (begin
    (let ((decayed-multiplier (/ (* (var-get volatility-multiplier) VOLATILITY_DECAY_RATE) u1000000))
          (decayed-volatility (/ (* (var-get current-volatility) VOLATILITY_DECAY_RATE) u1000000)))
      (var-set volatility-multiplier (if (> decayed-multiplier u1000000) decayed-multiplier u1000000))
      (var-set current-volatility decayed-volatility)
      (ok decayed-multiplier))))

(define-public (get-adjusted-value (token-amount uint))
  (ok (/ (* token-amount (var-get volatility-multiplier)) u1000000)))

(define-public (burn-tokens (amount uint))
  (let ((sender tx-sender))
    (asserts! (not (var-get emergency-pause)) ERR_EMERGENCY_PAUSED)
    (asserts! (>= (get-balance sender) amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (try! (ft-burn? volatility-token amount sender))
    (map-set token-balances sender 
      (- (get-balance sender) amount))
    (var-set total-supply (- (var-get total-supply) amount))
    (ok true)))

(define-public (stake-tokens (amount uint))
  (let ((sender tx-sender)
        (current-stake (get-staked-balance sender)))
    (asserts! (not (var-get emergency-pause)) ERR_EMERGENCY_PAUSED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= (get-balance sender) amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (is-eq (get amount current-stake) u0) ERR_ALREADY_STAKED)
    (try! (transfer amount sender (as-contract tx-sender)))
    (map-set staked-balances sender 
      {amount: amount, stake-height: block-height, last-claim: block-height})
    (var-set total-staked (+ (var-get total-staked) amount))
    (ok true)))

(define-public (unstake-tokens)
  (let ((sender tx-sender)
        (stake-info (get-staked-balance sender))
        (staked-amount (get amount stake-info))
        (stake-height (get stake-height stake-info)))
    (asserts! (not (var-get emergency-pause)) ERR_EMERGENCY_PAUSED)
    (asserts! (> staked-amount u0) ERR_NOT_STAKED)
    (asserts! (>= (- block-height stake-height) UNSTAKE_COOLDOWN) ERR_COOLDOWN_ACTIVE)
    (try! (as-contract (transfer staked-amount tx-sender sender)))
    (map-delete staked-balances sender)
    (var-set total-staked (- (var-get total-staked) staked-amount))
    (ok staked-amount)))

(define-public (claim-rewards)
  (let ((sender tx-sender)
        (stake-info (get-staked-balance sender))
        (rewards (calculate-rewards sender)))
    (asserts! (not (var-get emergency-pause)) ERR_EMERGENCY_PAUSED)
    (asserts! (> (get amount stake-info) u0) ERR_NOT_STAKED)
    (asserts! (> rewards u0) ERR_INVALID_AMOUNT)
    (asserts! (>= (var-get reward-pool) rewards) ERR_INSUFFICIENT_BALANCE)
    (try! (ft-mint? volatility-token rewards sender))
    (map-set token-balances sender 
      (+ (get-balance sender) rewards))
    (map-set staked-balances sender 
      (merge stake-info {last-claim: block-height}))
    (var-set reward-pool (- (var-get reward-pool) rewards))
    (var-set total-supply (+ (var-get total-supply) rewards))
    (ok rewards)))

(define-public (add-to-reward-pool (amount uint))
  (begin
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (try! (transfer amount tx-sender (as-contract tx-sender)))
    (var-set reward-pool (+ (var-get reward-pool) amount))
    (ok true)))

(define-public (add-oracle-operator (operator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set oracle-operators operator true)
    (ok true)))

(define-public (remove-oracle-operator (operator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-delete oracle-operators operator)
    (ok true)))

(define-public (oracle-price-update (new-price uint) (signature (buff 65)))
  (begin
    (asserts! (is-oracle-operator tx-sender) ERR_UNAUTHORIZED)
    (asserts! (not (var-get emergency-pause)) ERR_EMERGENCY_PAUSED)
    (asserts! (> new-price u0) ERR_INVALID_AMOUNT)
    (try! (update-btc-price new-price))
    (ok true)))

(define-public (emergency-price-update (new-price uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (not (is-oracle-data-fresh)) ERR_ORACLE_STALE)
    (try! (update-btc-price new-price))
    (ok true)))

(define-public (emergency-pause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set emergency-pause true)
    (ok true)))

(define-public (emergency-unpause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set emergency-pause false)
    (ok true)))

(define-public (create-governance-proposal (description (string-ascii 256)))
  (let ((proposal-id (+ (var-get total-supply) block-height))
        (sender tx-sender))
    (asserts! (>= (get-balance sender) (var-get governance-threshold)) ERR_INSUFFICIENT_BALANCE)
    (map-set governance-proposals proposal-id 
      {proposer: sender, description: description, votes-for: u0, votes-against: u0, executed: false})
    (ok proposal-id)))

(define-public (vote-on-proposal (proposal-id uint) (vote-for bool))
  (let ((sender tx-sender)
        (proposal (unwrap! (get-governance-proposal proposal-id) ERR_INVALID_AMOUNT))
        (user-balance (get-balance sender)))
    (asserts! (> user-balance u0) ERR_INSUFFICIENT_BALANCE)
    (asserts! (is-none (map-get? user-votes {proposal-id: proposal-id, voter: sender})) ERR_ALREADY_STAKED)
    (map-set user-votes {proposal-id: proposal-id, voter: sender} true)
    (if vote-for
        (map-set governance-proposals proposal-id 
          (merge proposal {votes-for: (+ (get votes-for proposal) user-balance)}))
        (map-set governance-proposals proposal-id 
          (merge proposal {votes-against: (+ (get votes-against proposal) user-balance)})))
    (ok true)))

(define-public (execute-proposal (proposal-id uint))
  (let ((proposal (unwrap! (get-governance-proposal proposal-id) ERR_INVALID_AMOUNT))
        (total-votes (+ (get votes-for proposal) (get votes-against proposal))))
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> (get votes-for proposal) (get votes-against proposal)) ERR_UNAUTHORIZED)
    (asserts! (> total-votes (/ (var-get total-supply) u2)) ERR_INSUFFICIENT_BALANCE)
    (asserts! (not (get executed proposal)) ERR_ALREADY_STAKED)
    (map-set governance-proposals proposal-id 
      (merge proposal {executed: true}))
    (ok true)))

(define-public (request-unstake)
  (let ((sender tx-sender)
        (stake-info (get-staked-balance sender)))
    (asserts! (not (var-get emergency-pause)) ERR_EMERGENCY_PAUSED)
    (asserts! (> (get amount stake-info) u0) ERR_NOT_STAKED)
    (map-set unstake-requests sender block-height)
    (ok true)))

(define-public (complete-unstake)
  (let ((sender tx-sender)
        (request-height (default-to u0 (map-get? unstake-requests sender)))
        (stake-info (get-staked-balance sender))
        (staked-amount (get amount stake-info)))
    (asserts! (not (var-get emergency-pause)) ERR_EMERGENCY_PAUSED)
    (asserts! (> request-height u0) ERR_NOT_STAKED)
    (asserts! (>= (- block-height request-height) UNSTAKE_COOLDOWN) ERR_COOLDOWN_ACTIVE)
    (try! (as-contract (transfer staked-amount tx-sender sender)))
    (map-delete staked-balances sender)
    (map-delete unstake-requests sender)
    (var-set total-staked (- (var-get total-staked) staked-amount))
    (ok staked-amount)))

(define-public (compound-rewards)
  (let ((sender tx-sender)
        (stake-info (get-staked-balance sender))
        (rewards (calculate-rewards sender))
        (current-staked (get amount stake-info)))
    (asserts! (not (var-get emergency-pause)) ERR_EMERGENCY_PAUSED)
    (asserts! (> current-staked u0) ERR_NOT_STAKED)
    (asserts! (> rewards u0) ERR_INVALID_AMOUNT)
    (asserts! (>= (var-get reward-pool) rewards) ERR_INSUFFICIENT_BALANCE)
    (map-set staked-balances sender 
      (merge stake-info {amount: (+ current-staked rewards), last-claim: block-height}))
    (var-set total-staked (+ (var-get total-staked) rewards))
    (var-set reward-pool (- (var-get reward-pool) rewards))
    (ok rewards)))

(define-public (set-governance-threshold (new-threshold uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set governance-threshold new-threshold)
    (ok true)))