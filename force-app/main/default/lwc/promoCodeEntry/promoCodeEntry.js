import { LightningElement, api } from "lwc";
import applyCodes from "@salesforce/apex/PromoCodeApplyService.apply";
import getCurrentlyApplied from "@salesforce/apex/PromoCodeApplyService.getCurrentlyApplied";

/**
 * Member-facing inline panel for entering promo codes at checkout. Validates each code via Apex,
 * renders per-code error banners for failed attempts, and surfaces the total savings summary.
 *
 * Per-code Remove re-applies the current set minus the removed code (Phase A2 design: one Apply
 * event = one applicationGroupId, so removing a single code is implemented as a re-apply with a
 * smaller list). The parent Checkout LWC consumes events to drive re-pricing and place-order
 * gating.
 *
 * Public API:
 *   @api orderId  — Order Id the codes apply to. Required.
 *   @api disabled — When true, all inputs/buttons are disabled (use while parent is in async work).
 *
 * Events:
 *   codesapplied    detail = { applicationGroupId, codes: [{code, currencyIsoCode, appliedAmount}], totalAdjustment }
 *   codesremoved    detail = { applicationGroupId }  // fires on any Remove that successfully re-applies
 *   validationerror detail = { codeResults: [{code, valid, errorCode, errorMessage}] }  // any apply that had ≥ 1 failure
 */
export default class PromoCodeEntry extends LightningElement {
  /** @type {string} Order Id the codes apply to. Required for any Apex call. */
  @api orderId;

  /**
   * Auto-injected by Lightning when the LWC is placed on an Order record page (internal
   * Lightning Experience). Lets staff drop the component on the Order flexipage and have
   * it self-bind to the record, without wiring the `orderId` property in App Builder.
   * The component prefers `orderId` when both are set so the checkout integration is
   * unaffected.
   */
  @api recordId;

  /** @type {boolean} When true, the LWC disables all interactive controls. */
  @api disabled = false;

  showInput = false;
  inputValue = "";
  appliedCodes = [];
  failedCodes = [];
  isLoading = false;
  applicationGroupId;
  _autoLoaded = false;

  // -----------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------

  connectedCallback() {
    // Auto-load currently-applied codes when mounted on a record page. The parent
    // Checkout LWC sets `orderId` and drives state via setAppliedCodes() — for that flow
    // we skip the auto-load (no recordId is injected outside record pages). For Order
    // record pages, recordId is set automatically and we self-bind.
    const targetOrderId = this.effectiveOrderId;
    if (targetOrderId && !this._autoLoaded) {
      this._autoLoaded = true;
      this._loadApplied(targetOrderId);
    }
  }

  // -----------------------------------------------------------
  // Effective Order Id resolution
  // -----------------------------------------------------------

  /**
   * The Order Id used for all Apex calls. Prefers `orderId` (explicitly set by a parent
   * component or App Builder property) and falls back to `recordId` (auto-injected by the
   * record-page framework). Returns null if neither is set.
   */
  get effectiveOrderId() {
    return this.orderId || this.recordId || null;
  }

  // -----------------------------------------------------------
  // Public methods (parent can call these to reset / pre-load)
  // -----------------------------------------------------------

  /**
   * Replaces the displayed applied-codes set without calling Apex. Useful when the parent
   * already has cart state (e.g., after a navigate-back) and wants to seed the panel.
   * @param {Array<{code, currencyIsoCode, displayName, appliedAmount}>} codes
   */
  @api
  setAppliedCodes(codes) {
    this.appliedCodes = Array.isArray(codes) ? codes.slice() : [];
    this.failedCodes = [];
  }

  // -----------------------------------------------------------
  // Getters
  // -----------------------------------------------------------

  get controlsDisabled() {
    return this.disabled || this.isLoading;
  }

  get applyDisabled() {
    return this.controlsDisabled || !(this.inputValue || "").trim();
  }

  get hasAppliedCodes() {
    return this.appliedCodes.length > 0;
  }

  get hasFailedCodes() {
    return this.failedCodes.length > 0;
  }

  get totalAdjustment() {
    return this.appliedCodes.reduce(
      (sum, c) => sum + (Number(c.appliedAmount) || 0),
      0
    );
  }

  get summaryCurrency() {
    const first = this.appliedCodes[0];
    return first ? first.currencyIsoCode : null;
  }

  // -----------------------------------------------------------
  // User actions
  // -----------------------------------------------------------

  handleShowInput() {
    this.showInput = true;
    // Defer focus to next tick so the input is rendered.
    Promise.resolve().then(() => {
      const input = this.template.querySelector(".code-input");
      if (input && typeof input.focus === "function") input.focus();
    });
  }

  handleCancelInput() {
    this.showInput = false;
    this.inputValue = "";
  }

  handleInputChange(event) {
    this.inputValue = event.target.value;
  }

  handleInputKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      this.handleApply();
    }
  }

  handleApply() {
    const newCode = (this.inputValue || "").trim();
    if (!newCode) return;

    const currentCodes = this.appliedCodes.map((c) => c.code);
    const failedToRetain = this.failedCodes
      .map((c) => c.code)
      .filter((code) => code.toUpperCase() !== newCode.toUpperCase());
    const submittedCodes = [...currentCodes, ...failedToRetain, newCode];

    this._callApply(submittedCodes, { isAdd: true });
  }

  handleRemove(event) {
    const codeToRemove = event.currentTarget.dataset.code;
    if (!codeToRemove) return;
    const remaining = this.appliedCodes
      .map((c) => c.code)
      .filter((code) => code !== codeToRemove);

    if (remaining.length === 0) {
      // Skip the Apex round-trip when nothing's left to apply — just clear local state.
      const previousGroupId = this.applicationGroupId;
      this.appliedCodes = [];
      this.applicationGroupId = null;
      this.dispatchEvent(
        new CustomEvent("codesremoved", {
          detail: { applicationGroupId: previousGroupId }
        })
      );
      return;
    }

    const failedToRetain = this.failedCodes.map((c) => c.code);
    this._callApply([...remaining, ...failedToRetain], { isRemove: true });
  }

  handleDismissFailed(event) {
    const codeToDismiss = event.currentTarget.dataset.code;
    this.failedCodes = this.failedCodes.filter((c) => c.code !== codeToDismiss);
  }

  // -----------------------------------------------------------
  // Apex call orchestration
  // -----------------------------------------------------------

  async _loadApplied(orderId) {
    this.isLoading = true;
    try {
      const result = await getCurrentlyApplied({ orderId });
      if (!result || !result.codeResults) return;
      const applied = result.codeResults
        .filter((cr) => cr.valid)
        .map((cr) => ({
          code: cr.code,
          currencyIsoCode: cr.currencyIsoCode,
          displayName: cr.displayName,
          appliedAmount: cr.appliedAmount
        }));
      this.appliedCodes = applied;
      this.applicationGroupId = result.applicationGroupId || null;
    } catch (err) {
      // Soft-fail: an Order record page should still render even if the loader errors.
      console.error("promoCodeEntry: getCurrentlyApplied failed", err);
    } finally {
      this.isLoading = false;
    }
  }

  async _callApply(codes, { isAdd = false, isRemove = false } = {}) {
    const orderId = this.effectiveOrderId;
    if (!orderId) {
      console.error("promoCodeEntry: orderId is required");
      return;
    }

    this.isLoading = true;
    try {
      const previousGroupId = this.applicationGroupId;
      const result = await applyCodes({ orderId, codes });

      const applied = [];
      const failed = [];
      (result.codeResults || []).forEach((cr) => {
        if (cr.valid) {
          applied.push({
            code: cr.code,
            currencyIsoCode: cr.currencyIsoCode,
            displayName: cr.displayName,
            appliedAmount: cr.appliedAmount
          });
        } else {
          failed.push({
            code: cr.code,
            errorCode: cr.errorCode,
            errorMessage: cr.errorMessage
          });
        }
      });

      this.appliedCodes = applied;
      this.failedCodes = failed;
      this.applicationGroupId = result.applicationGroupId || null;

      if (isAdd) {
        this.inputValue = "";
        this.showInput = false;
      }

      if (applied.length > 0) {
        this.dispatchEvent(
          new CustomEvent("codesapplied", {
            detail: {
              applicationGroupId: this.applicationGroupId,
              codes: applied,
              totalAdjustment: this.totalAdjustment
            }
          })
        );
      }

      if (isRemove) {
        this.dispatchEvent(
          new CustomEvent("codesremoved", {
            detail: { applicationGroupId: previousGroupId }
          })
        );
      }

      if (failed.length > 0) {
        this.dispatchEvent(
          new CustomEvent("validationerror", {
            detail: { codeResults: result.codeResults }
          })
        );
      }
    } catch (err) {
      console.error("promoCodeEntry: applyCodes failed", err);
      this.failedCodes = [
        ...this.failedCodes,
        {
          code: codes[codes.length - 1],
          errorCode: "UNEXPECTED_ERROR",
          errorMessage: "Could not apply right now. Please try again."
        }
      ];
    } finally {
      this.isLoading = false;
    }
  }
}
