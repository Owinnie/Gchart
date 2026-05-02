# Project 2 Draft  
## Hidden Markov Model Regime Detection and Bayesian Network Forecasting for WTI Crude Oil

### How this draft maps to your assignment
- **Step 1**: Sections 2.1-2.3 (Forward/Backward, Viterbi, Baum-Welch pseudocode + toy examples).
- **Step 2**: Section 3 (bull, bear, stagnant regime identification and illustrations).
- **Step 3**: Section 4 (new definition of HMM with updated references).
- **Step 4**: Sections 5-7 (design, data pipeline, regime process in `hmms`, and BN training/testing in `pgmpy`).
- **Step 5**: Entire document is written as one integrated narrative (you can submit as a single paper after formatting and adding figures from your notebook).

---

## 1. Introduction

Project 2 extends the methodology developed in Project 1 by operationalizing a two-layer probabilistic workflow for crude oil forecasting. The first layer is a **Hidden Markov Model (HMM)** that classifies the oil market into latent regimes (bull, bear, stagnant) from return dynamics. The second layer is a **Bayesian Network (BN)** that models directional dependencies among macroeconomic, microeconomic, and financial variables, then infers next-period oil-price behavior under uncertainty (Koller and Friedman; Pearl).

This design is appropriate for crude oil because oil returns are known to be non-Gaussian, heavy-tailed, and regime-dependent, especially around geopolitical disruptions, policy shocks, and demand collapses (Kilian; Hamilton). A single linear model is often too rigid for this data-generating process. In contrast, regime-switching models and graphical models jointly provide:

1. **State awareness** (via HMM latent regimes),
2. **Probabilistic interpretability** (via BN conditional structure),
3. **Actionable uncertainty estimates** instead of point-only predictions (Rabiner; Zucchini, MacDonald, and Langrock).

---

## 2. Step 1: HMM Algorithms and Toy Examples

## 2.1 Forward and Backward Algorithms

### 2.1.1 Forward algorithm pseudocode

Let:
- Hidden states: \(S = \{1,\dots,N\}\)
- Observations: \(O = (o_1,\dots,o_T)\)
- Initial distribution: \(\pi_i = P(q_1=i)\)
- Transition matrix: \(a_{ij} = P(q_{t+1}=j \mid q_t=i)\)
- Emission probabilities: \(b_j(o_t)=P(o_t\mid q_t=j)\)

**Goal:** compute \(P(O\mid \lambda)\), where \(\lambda=(A,B,\pi)\).

```text
FORWARD(O, A, B, pi):
    # Initialization
    for i in 1..N:
        alpha[1, i] = pi[i] * B[i, o1]

    # Recursion
    for t in 1..T-1:
        for j in 1..N:
            alpha[t+1, j] = B[j, o_{t+1}] * sum_{i=1..N}(alpha[t, i] * A[i, j])

    # Termination
    p_obs = sum_{i=1..N}(alpha[T, i])
    return alpha, p_obs
```

### 2.1.2 Backward algorithm pseudocode

```text
BACKWARD(O, A, B):
    # Initialization
    for i in 1..N:
        beta[T, i] = 1

    # Recursion
    for t in T-1 down to 1:
        for i in 1..N:
            beta[t, i] = sum_{j=1..N}(A[i, j] * B[j, o_{t+1}] * beta[t+1, j])

    return beta
```

Posterior state probability:
\[
\gamma_t(i)=P(q_t=i\mid O,\lambda)=\frac{\alpha_t(i)\beta_t(i)}{P(O\mid \lambda)}.
\]

### 2.1.3 Toy example (worked)

Assume two hidden states:
- \(0=\) Bull, \(1=\) Bear

Two observable symbols:
- Up, Down

Parameters:
- \(\pi=[0.6, 0.4]\)
- \(A=\begin{bmatrix}0.8 & 0.2\\0.3 & 0.7\end{bmatrix}\)
- \(B(\text{Up})=[0.7, 0.4],\ B(\text{Down})=[0.3,0.6]\)

Observation sequence: \(O=(\text{Down}, \text{Up}, \text{Up})\).

Forward values:
- \( \alpha_1 = [0.18,\ 0.24] \)
- \( \alpha_2 = [0.1512,\ 0.0816] \)
- \( \alpha_3 = [0.101808,\ 0.034944] \)
- \( P(O\mid\lambda)=0.136752 \)

Backward values:
- \( \beta_3=[1,1] \)
- \( \beta_2=[0.64,\ 0.49] \)
- \( \beta_1=[0.3972,\ 0.2716] \)

Example posterior at \(t=2\):
\[
\gamma_2(\text{Bull})=\frac{0.1512\times0.64}{0.136752}=0.708,\quad
\gamma_2(\text{Bear})=0.292.
\]
So at \(t=2\), Bull is more likely than Bear.

---

## 2.2 Backward Viterbi (Viterbi with traceback) pseudocode + toy example

The Viterbi method computes the **single most likely hidden-state path**:
\[
q_{1:T}^*=\arg\max_{q_{1:T}} P(q_{1:T},O\mid\lambda)
\]
using dynamic programming plus a backward traceback (Rabiner).

```text
VITERBI_WITH_BACKTRACE(O, A, B, pi):
    # Initialization
    for i in 1..N:
        delta[1, i] = pi[i] * B[i, o1]
        psi[1, i] = 0

    # Forward DP recursion
    for t in 2..T:
        for j in 1..N:
            best_prev_val = -inf
            best_prev_state = None
            for i in 1..N:
                val = delta[t-1, i] * A[i, j]
                if val > best_prev_val:
                    best_prev_val = val
                    best_prev_state = i
            delta[t, j] = best_prev_val * B[j, o_t]
            psi[t, j] = best_prev_state

    # Termination
    q_star[T] = argmax_j delta[T, j]
    path_prob = max_j delta[T, j]

    # Backward traceback
    for t in T-1 down to 1:
        q_star[t] = psi[t+1, q_star[t+1]]

    return q_star, path_prob
```

### Toy result using same parameters as Section 2.1

From \(O=(\text{Down}, \text{Up}, \text{Up})\):
- \(\delta_1=[0.18,\ 0.24]\)
- \(\delta_2=[0.1008,\ 0.0672]\)
- \(\delta_3=[0.056448,\ 0.018816]\)

Final state: Bull.  
Traceback path: \([ \text{Bull},\ \text{Bull},\ \text{Bull}]\).

Interpretation: even with one bearish initial signal, persistence in the Bull state can dominate if transition strength is sufficiently high.

---

## 2.3 Baum-Welch algorithm pseudocode + toy example

Baum-Welch is the Expectation-Maximization (EM) training procedure for HMMs. It estimates \(A,B,\pi\) by maximizing \(P(O\mid\lambda)\) iteratively (Rabiner; Cappé, Moulines, and Rydén).

Define:
\[
\xi_t(i,j)=P(q_t=i,q_{t+1}=j\mid O,\lambda),\quad
\gamma_t(i)=P(q_t=i\mid O,\lambda).
\]

```text
BAUM_WELCH(O, N, M, max_iter, tol):
    initialize A, B, pi
    prev_loglik = -inf

    for iter in 1..max_iter:
        # E-step: forward-backward
        alpha, p_obs = FORWARD(O, A, B, pi)
        beta = BACKWARD(O, A, B)

        for t in 1..T-1:
            denom = sum_i sum_j alpha[t,i] * A[i,j] * B[j,o_{t+1}] * beta[t+1,j]
            for i in 1..N:
                for j in 1..N:
                    xi[t,i,j] = alpha[t,i] * A[i,j] * B[j,o_{t+1}] * beta[t+1,j] / denom

        for t in 1..T:
            denom = sum_i alpha[t,i] * beta[t,i]
            for i in 1..N:
                gamma[t,i] = alpha[t,i] * beta[t,i] / denom

        # M-step: parameter updates
        for i in 1..N:
            pi_new[i] = gamma[1,i]
            for j in 1..N:
                A_new[i,j] = sum_{t=1..T-1} xi[t,i,j] / sum_{t=1..T-1} gamma[t,i]
            for k in 1..M:
                B_new[i,k] = sum_{t: o_t = k} gamma[t,i] / sum_{t=1..T} gamma[t,i]

        A, B, pi = A_new, B_new, pi_new
        loglik = log(p_obs)
        if abs(loglik - prev_loglik) < tol:
            break
        prev_loglik = loglik

    return A, B, pi, loglik
```

### Toy one-iteration illustration

Using the same two-state, two-symbol setup and \(O=(\text{Down}, \text{Up}, \text{Up})\), one EM iteration gives approximate updates:

- \(\pi' \approx [0.523,\ 0.477]\)
- \(A' \approx \begin{bmatrix}0.886 & 0.114\\0.470 & 0.530\end{bmatrix}\)
- \(B'_{\text{Bull}}(\text{Up})\approx0.735,\ B'_{\text{Bull}}(\text{Down})\approx0.265\)
- \(B'_{\text{Bear}}(\text{Up})\approx0.535,\ B'_{\text{Bear}}(\text{Down})\approx0.465\)

Interpretation: the fitted model becomes more persistent in Bull and assigns higher Up-emission probability to Bull, as expected from an observation sequence ending with repeated Up outcomes.

---

## 3. Step 2: Regime Identification and Illustration (Bull, Bear, Stagnant)

Using a 3-state Gaussian HMM fitted to WTI log returns, each latent state is labeled by its estimated mean and variance:

- **Bull regime**: positive mean return, low-to-moderate variance.
- **Bear regime**: negative mean return, highest variance.
- **Stagnant regime**: near-zero mean return, low variance.

Your current estimates:

| State | Mean Return | Variance | Label |
|---|---:|---:|---|
| State 1 | 0.001137 | 0.000272 | Bull |
| State 0 | -0.000292 | 0.000339 | Stagnant |
| State 2 | -0.001704 | 0.003122 | Bear |

This mapping is statistically coherent: the bear state has both the most negative drift and much larger dispersion.

### 3.1 Bull regime examples (illustrative windows)
1. **Recovery/expansion phases** where decoded state = Bull for extended runs (e.g., post-slump rebounds).  
2. **Sustained uptrends** where positive monthly returns cluster and volatility remains controlled.

What to show in your figure:
- WTI price series with Bull segments overlaid in green.
- Optional panel with state posterior probabilities to show confidence.

### 3.2 Bear regime examples (illustrative windows)
1. **Crash dynamics**, especially COVID-19 demand collapse windows.
2. **Sharp drawdown periods** with large negative returns and volatility spikes.

What to show:
- WTI series with Bear segments in red.
- Zoom panel around crash period to demonstrate high-variance state occupancy.

### 3.3 Stagnant regime examples (illustrative windows)
1. **Range-bound markets** where trend is weak and net drift is near zero.
2. **Transition corridors** between strong bull and strong bear episodes.

What to show:
- WTI series with Stagnant segments in amber/yellow.
- Histogram of returns by state to show stagnant mean near zero.

### Suggested figure captions (ready to paste)
- **Figure 2.1**. Decoded 3-state HMM regimes on WTI spot prices (Bull=green, Bear=red, Stagnant=yellow).
- **Figure 2.2**. State-dependent return distributions: Bear regime has the widest tails and most negative center.
- **Figure 2.3**. Smoothed posterior probabilities (\(\gamma_t\)) showing regime persistence and transitions.

---

## 4. Step 3: Updated Definition of Hidden Markov Model (1-2 pages)

### Definition 3 (reformulated)

A **Hidden Markov Model (HMM)** is a latent-variable time-series model in which:

1. An unobserved state process \(S_1,\dots,S_T\) evolves as a first-order Markov chain on a finite state space \(\{1,\dots,K\}\), and  
2. Each observation \(Y_t\) is conditionally generated from an emission distribution indexed by the current hidden state \(S_t\).

Formally, an HMM is parameterized by
\[
\lambda = (\pi, A, \Theta),
\]
where:
- \(\pi_i = P(S_1=i)\) is the initial-state distribution,
- \(A=[a_{ij}]\), \(a_{ij}=P(S_{t+1}=j\mid S_t=i)\), is the transition matrix,
- \(\Theta\) is the emission parameter set (e.g., Gaussian \(\mu_i,\Sigma_i\) for each state \(i\)).

The model imposes two structural assumptions:

1. **Markov state dynamics**  
\[
P(S_{t+1}\mid S_t,S_{t-1},\dots,S_1)=P(S_{t+1}\mid S_t).
\]

2. **Conditional emission independence**  
\[
P(Y_t\mid S_{1:T},Y_{1:t-1},Y_{t+1:T}) = P(Y_t\mid S_t).
\]

Therefore, the complete-data joint density factorizes as:
\[
P(S_{1:T},Y_{1:T})
= P(S_1)\prod_{t=1}^{T-1}P(S_{t+1}\mid S_t)\prod_{t=1}^{T}P(Y_t\mid S_t).
\]

In financial regime applications, each hidden state represents a latent market condition (such as bullish trend, bearish stress, or stagnation), while emissions are observed returns or return-derived features. This architecture separates the **regime process** from the **measurement process**, which is valuable when structural market states are not directly observable but strongly influence observable price behavior (Hamilton; Zucchini, MacDonald, and Langrock).

From an inference perspective, HMMs support three core computational tasks:
- **Filtering / smoothing** (forward-backward),
- **Most likely state path** (Viterbi),
- **Parameter estimation** (Baum-Welch / EM).

These tasks are computationally tractable because dynamic programming reduces exponential sequence complexity to polynomial-time recursion (Rabiner). For oil markets, this is particularly useful because volatility clustering, abrupt transitions, and non-stationary risk are more naturally represented as state changes than as static linear residual behavior (Kilian; Hamilton).

**Why this definition is stronger for your paper:** it explicitly separates latent process assumptions, observation assumptions, and algorithmic consequences, which creates a clear bridge from theory (Definition 3) to implementation (Step 1 pseudocode and Step 2 regime decoding).

---

## 5. Step 4(a): Macro Research, Indicator Identification, Retrieval, and Cleaning Design

This section can be used as your first major methodology chapter (up to 5 pages after formatting/figures).

### 5.1 Macro research rationale

The variable design follows the structural oil-price literature that decomposes oil movements into supply-side shocks, aggregate demand shocks, and precautionary/speculative demand channels (Kilian). That theoretical framing aligns with the dissertation pipeline and motivates combining:

1. **Macroeconomic indicators** (production, inflation, capacity metrics),
2. **Physical market micro indicators** (OPEC/non-OPEC production, inventories, refinery flows),
3. **Financial/risk proxies** (equities, dollar index, VIX, commodity futures).

This tri-layer specification avoids underfitting caused by single-domain datasets and supports causal interpretation in the later BN stage.

### 5.2 Indicator identification process

Indicators were retained if they satisfied three criteria:

1. **Economic plausibility** (clear channel to oil pricing),
2. **Data continuity** over the sample horizon,
3. **Frequency harmonization feasibility** for monthly modeling.

Core examples:
- **Demand cycle proxies**: Industrial production, copper futures.
- **Dollar channel**: USD index for commodity-pricing inverse effects.
- **Supply constraints**: OPEC production and surplus capacity.
- **Risk sentiment**: VIX and energy equities.
- **Benchmark linkage**: Brent futures to capture cross-benchmark structure.

### 5.3 Dataset retrieval architecture

Following your Project 1 pipeline:
- **FRED API** for macro series and WTI spot benchmark.
- **EIA API / STEO browser** for supply-demand-inventory fundamentals.
- **Yahoo Finance (`yfinance`)** for market and futures factors.

All series are converted to a common monthly index (2010-2024), then merged into a panel.

### 5.4 Data retrieval issues and technical fixes

The most severe retrieval friction came from EIA workflows, including:
- endpoint/series ID migration mismatches,
- intermittent server errors (5xx),
- date-type inconsistency across period encodings,
- frequency mismatch for annual/quarterly series.

Practical fixes:
- post-download period standardization in pandas before filtering,
- retry-capable wrappers for transient API failures,
- endpoint ID updates to v2-compatible forms,
- manual CSV fallback for non-monthly series with controlled temporal upsampling.

This is methodologically important: reproducibility depends not only on model code but also on robust extraction logic and documented fallback paths.

### 5.5 Cleaning protocol and statistical validity

The cleaning process should be explicitly documented as a sequence:

1. **Schema and index checks**  
   - unique timestamps, monotonic dates, type consistency.
2. **Frequency harmonization**  
   - daily financial series aggregated/aligned to month-end representation.
3. **Missing-value treatment**  
   - constrained forward/backward fills only where economically valid.
4. **Extreme outlier policy (IQR on returns, \(k=3\))**  
   - outliers replaced with `NaN` then re-imputed under transparent rules.
5. **Final complete-case alignment**  
   - synchronized panel ready for supervised target construction.

Using return-space outlier detection (instead of level-space clipping) is appropriate for commodities because level shifts can be economically meaningful, while return extremes are more directly tied to transient shock noise versus structural trend.

### 5.6 Deliverables for this chapter

Include these in your final submission:
- A source-by-source retrieval table (success rates and final shapes),
- Missingness table (before/after imputation),
- Outlier table (flag counts and economic interpretation),
- Final shape table after target creation.

These tables give examiners traceability from raw source to modeling matrix.

---

## 6. Step 4(b): Regime Process and How `hmms` Code Works

This section explains the regime engine implementation (up to 5 pages with figures/code snippets).

### 6.1 Regime-model objective

The HMM stage transforms continuous return dynamics into latent regimes with distinct drift-volatility profiles:
- Bull: positive drift, lower variance,
- Bear: negative drift, high variance,
- Stagnant: near-zero drift, low variance.

This is not only descriptive; regime labels become features (or discretized states) for downstream BN learning.

### 6.2 Typical `hmms` pipeline logic (implementation blueprint)

```text
1. Load cleaned monthly WTI price series
2. Compute log returns: r_t = ln(P_t / P_{t-1})
3. Standardize or center features (optional but common)
4. Fit GaussianHMM(n_components=3, covariance_type="full", n_iter=...)
5. Decode hidden states (Viterbi or posterior argmax)
6. Compute state statistics: mean return, variance, occupancy
7. Map numeric states -> semantic labels (Bull/Bear/Stagnant)
8. Visualize:
   - prices with regime colors
   - return distributions by regime
   - posterior regime probabilities
9. Export regime series for BN stage
```

### 6.3 Key code concepts to explain in your write-up

1. **Initialization sensitivity**  
   HMM EM training can settle at local optima; use multiple seeds/restarts and compare log-likelihood.

2. **Label-switching management**  
   HMM state indices are arbitrary; map states by estimated means/variances each run.

3. **State persistence diagnostics**  
   Interpret diagonal of transition matrix \(A\). High \(a_{ii}\) implies regime persistence.

4. **Posterior confidence checks**  
   Use \(\gamma_t(i)\) to identify ambiguous transition periods.

5. **Regime plausibility validation**  
   Confirm bear-state occupancy spikes around known stress episodes.

### 6.4 Example interpretation paragraph (ready to use)

> The fitted three-state Gaussian HMM recovered a high-volatility negative-drift state that aligns with known crisis episodes, a low-volatility positive-drift state corresponding to expansionary periods, and an intermediate near-zero state consistent with market consolidation. This supports the economic validity of the latent-state interpretation and justifies using regime labels as structured inputs in the subsequent Bayesian Network stage.

### 6.5 Suggested code-level appendix points

- Library: `hmmlearn` (`GaussianHMM`) for EM-based fitting.
- Hyperparameters to document: `n_components`, `covariance_type`, `n_iter`, `tol`, random seed, and number of restarts.
- Output artifacts: decoded state vector, transition matrix, per-state moments, and plotted overlays.

---

## 7. Step 4(c): BN Training in `pgmpy`, Parameter Testing, and Validation

This chapter explains how regime-enriched data is converted into a causal probabilistic forecasting model (up to 5 pages with equations/tables).

### 7.1 Data handoff from HMM to BN

After HMM decoding, the modeling matrix includes:
- original cleaned factors,
- regime indicators (or discretized market state proxies),
- forecast target \(WTI\_Spot\_Price_{t+1}\).

Because classical BN implementations are often discrete, continuous variables can be discretized using economically meaningful bins (quantiles, regime thresholds, or domain rules).

### 7.2 Structure learning in `pgmpy`

A score-based search is appropriate for moderate-dimensional economic systems:
- **Search**: `HillClimbSearch`
- **Score**: BIC (or alternative score for discrete data)
- **Constraints**: optional expert priors (e.g., forbid future-to-past edges)

Conceptually:

```text
1. Define candidate node set V
2. Impose temporal/causal constraints
3. Run hill climbing to maximize BIC score
4. Return DAG G*
```

This yields an interpretable graph where parent sets of the WTI target provide direct drivers under the learned structure (Koller and Friedman; Pearl).

### 7.3 Parameter learning

Given learned DAG \(G^*\), estimate CPTs with Bayesian smoothing:
- `BayesianEstimator`
- BDeu prior
- chosen equivalent sample size (ESS)

Bayesian estimation is preferred over pure MLE in sparse state combinations, reducing zero-probability artifacts and improving inference stability.

### 7.4 Inference and forecasting workflow

Once \(G^*\) and CPTs are fitted:
1. Set evidence from observed \(t\)-period variables,
2. Infer posterior distribution of \(WTI_{t+1}\) regime/value class,
3. Convert posterior to decision metrics (most likely class, entropy, confidence-weighted signal).

### 7.5 Validation framework (what to report)

Use walk-forward or rolling-origin validation to prevent look-ahead bias.

Recommended metrics:
- Predictive log-likelihood,
- Regime/classification accuracy (if discretized),
- Brier score or calibration error for probabilistic forecasts,
- Confusion matrix by regime,
- Sensitivity of performance to ESS and discretization scheme.

### 7.6 Robustness and diagnostics

Minimum diagnostics to include:
- Stability of learned edges across bootstrap samples,
- Consistency of WTI Markov blanket composition,
- Performance difference with/without HMM-derived regime features.

If regime features improve calibration and regime-hit rates, that empirically supports the two-layer architecture.

---

## 8. Step 5: Integrated Narrative (10-15 page structure)

The final paper can be organized as below (this draft already follows it):

1. **Problem and motivation**: oil-price nonlinearity and uncertainty.
2. **Data and preprocessing**: multi-source retrieval + cleaning governance.
3. **HMM theory and algorithms**: forward/backward, Viterbi, Baum-Welch.
4. **Empirical regime extraction**: bull/bear/stagnant identification and plots.
5. **Graphical causal modeling**: BN structure and parameter learning in `pgmpy`.
6. **Validation and interpretation**: out-of-sample performance and causal insight.
7. **Conclusion**: implications for forecasting and risk-aware decision-making.

### Integrated discussion paragraph (ready to paste into conclusion)

> The combined HMM-BN framework addresses two core limitations of orthodox crude-oil forecasting models: hidden regime shifts and opaque dependence structures. The HMM layer extracts latent market states that summarize nonlinear volatility-trend behavior, while the BN layer transforms macro, micro, and financial evidence into interpretable conditional forecasts for the next period. This creates a workflow that is both statistically adaptive and economically interpretable, which is critical for high-volatility energy markets.

---

## 9. Conclusion

Project 2 operationalizes the dissertation’s probabilistic modeling philosophy into reproducible algorithmic stages. The HMM component provides latent-state segmentation and state-transition probabilities; the BN component provides causal structure and probabilistic forecasting under uncertainty. Together they produce a coherent methodology that is transparent, flexible under mixed-domain inputs, and suitable for regime-sensitive oil-price analysis.

For submission quality, the most important final step is presentation: add your generated figures (regime overlays, posterior plots, DAG image), align table numbering, and keep terminology consistent across all sections (especially state labels and variable names).

---

## Works Cited (MLA 9th ed.)

Alvi, S. M. (or full author name in your dissertation). *[Dissertation Title on Crude Oil Forecasting with Probabilistic Graphical Models]*. 2018. PhD dissertation.  

Cappé, Olivier, Eric Moulines, and Tobias Rydén. *Inference in Hidden Markov Models*. Springer, 2005.

Hamilton, James D. “A New Approach to the Economic Analysis of Nonstationary Time Series and the Business Cycle.” *Econometrica*, vol. 57, no. 2, 1989, pp. 357-384.

Kilian, Lutz. “Not All Oil Price Shocks Are Alike: Disentangling Demand and Supply Shocks in the Crude Oil Market.” *American Economic Review*, vol. 99, no. 3, 2009, pp. 1053-1069.

Koller, Daphne, and Nir Friedman. *Probabilistic Graphical Models: Principles and Techniques*. MIT Press, 2009.

Murphy, Kevin P. *Probabilistic Machine Learning: Advanced Topics*. MIT Press, 2023.

Pearl, Judea. *Probabilistic Reasoning in Intelligent Systems: Networks of Plausible Inference*. Morgan Kaufmann, 1988.

Rabiner, Lawrence R. “A Tutorial on Hidden Markov Models and Selected Applications in Speech Recognition.” *Proceedings of the IEEE*, vol. 77, no. 2, 1989, pp. 257-286.

Spirtes, Peter, Clark Glymour, and Richard Scheines. *Causation, Prediction, and Search*. 2nd ed., MIT Press, 2000.

Tsamardinos, Ioannis, Laura E. Brown, and Constantin F. Aliferis. “The Max-Min Hill-Climbing Bayesian Network Structure Learning Algorithm.” *Machine Learning*, vol. 65, no. 1, 2006, pp. 31-78.

Zucchini, Walter, Iain L. MacDonald, and Roland Langrock. *Hidden Markov Models for Time Series: An Introduction Using R*. 2nd ed., CRC Press, 2016.

`hmmlearn` developers. *hmmlearn Documentation*. GitHub Pages, https://hmmlearn.readthedocs.io/. Accessed 2 May 2026.

Ankan, Ankur, et al. *pgmpy Documentation*. pgmpy.org, https://pgmpy.org/. Accessed 2 May 2026.

---

### Final polishing checklist before you submit
- Replace placeholder dissertation citation for Alvi with exact MLA details.
- Insert your actual figures and cross-reference them in text.
- Keep one notation system throughout (e.g., \(S_t\), \(Y_t\), \(O_t\)).
- Ensure all table/figure captions use the same style.
- If required by your department, add hanging indents in Works Cited.
