import { LightningElement, api } from "lwc";
import applyCodes from "@salesforce/apex/PromoCodeApplyService.apply";
import getCurrentlyApplied from "@salesforce/apex/PromoCodeApplyService.getCurrentlyApplied";

import LBL_Title from "@salesforce/label/c.PromoCodeEntry_Title";
import LBL_AddBtn from "@salesforce/label/c.PromoCodeEntry_AddBtn";
import LBL_CodeFieldLabel from "@salesforce/label/c.PromoCodeEntry_CodeFieldLabel";
import LBL_CodePlaceholder from "@salesforce/label/c.PromoCodeEntry_CodePlaceholder";
import LBL_ApplyBtn from "@salesforce/label/c.PromoCodeEntry_ApplyBtn";
import LBL_CancelBtn from "@salesforce/label/c.PromoCodeEntry_CancelBtn";
import LBL_Working from "@salesforce/label/c.PromoCodeEntry_Working";
import LBL_RemoveCode from "@salesforce/label/c.PromoCodeEntry_RemoveCode";
import LBL_DismissFailed from "@salesforce/label/c.PromoCodeEntry_DismissFailed";
import LBL_DismissNotice from "@salesforce/label/c.PromoCodeEntry_DismissNotice";
import LBL_Dismiss from "@salesforce/label/c.PromoCodeEntry_Dismiss";
import LBL_TotalSavings from "@salesforce/label/c.PromoCodeEntry_TotalSavings";
import LBL_RetryMessage from "@salesforce/label/c.PromoCodeEntry_RetryMessage";

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

  // All user-facing strings are sourced from Custom Labels so the entire member-facing
  // surface area is translatable via the Translation Workbench. The template binds to
  // `label.<key>` rather than literal text.
  label = {
    title: LBL_Title,
    addBtn: LBL_AddBtn,
    codeFieldLabel: LBL_CodeFieldLabel,
    codePlaceholder: LBL_CodePlaceholder,
    applyBtn: LBL_ApplyBtn,
    cancelBtn: LBL_CancelBtn,
    working: LBL_Working,
    removeCode: LBL_RemoveCode,
    dismissFailed: LBL_DismissFailed,
    dismissNotice: LBL_DismissNotice,
    dismiss: LBL_Dismiss,
    totalSavings: LBL_TotalSavings
  };

  showInput = false;
  inputValue = "";
  appliedCodes = [];
  failedCodes = [];
  // Codes the apply service dropped via combinability resolution (errorCode
  // DROPPED_NON_COMBINABLE). Rendered as an info-style notice rather than an error so
  // the user sees a clear "we removed this for you" explanation. Surfacing them
  // separately keeps the failedCodes banner reserved for true validation failures.
  droppedCodes = [];
  isLoading = false;
  applicationGroupId;
  _autoLoaded = false;
  // Set by `setAppliedCodes`. Once true, an in-flight auto-load won't clobber the
  // caller's seed when it eventually resolves. Guards both Experience Cloud checkout
  // (parent calls setAppliedCodes after navigate-back) and unit tests.
  _externallySeeded = false;

  // -----------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------

  connectedCallback() {
    // Diagnostic — confirms which version is running + whether the framework injected
    // recordId on this page. Remove once Order-page integration is verified.
    console.log(
      "[promoCodeEntry] mounted",
      "orderId=",
      this.orderId,
      "recordId=",
      this.recordId,
      "effective=",
      this.effectiveOrderId
    );

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
    this._autoLoaded = true;
    this._externallySeeded = true;
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

  get hasDroppedCodes() {
    return this.droppedCodes.length > 0;
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

  handleDismissDropped(event) {
    const codeToDismiss = event.currentTarget.dataset.code;
    this.droppedCodes = this.droppedCodes.filter(
      (c) => c.code !== codeToDismiss
    );
  }

  // -----------------------------------------------------------
  // Apex call orchestration
  // -----------------------------------------------------------

  async _loadApplied(orderId) {
    this.isLoading = true;
    try {
      const result = await getCurrentlyApplied({ orderId });
      // If a caller already seeded state (via setAppliedCodes) while we were awaiting,
      // don't clobber their data.
      if (this._externallySeeded) return;
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
      const dropped = [];
      (result.codeResults || []).forEach((cr) => {
        if (cr.valid) {
          applied.push({
            code: cr.code,
            currencyIsoCode: cr.currencyIsoCode,
            displayName: cr.displayName,
            appliedAmount: cr.appliedAmount
          });
        } else if (cr.errorCode === "DROPPED_NON_COMBINABLE") {
          // Apex's combinability resolver removed this code because the cart has 2+
          // combinables that can stack. Surface it as an info notice rather than an
          // error and let the user dismiss it. The code is already absent from
          // appliedCodes, so the cart reflects the removal.
          dropped.push({
            code: cr.code,
            errorCode: cr.errorCode,
            errorMessage: cr.errorMessage
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
      this.droppedCodes = dropped;
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
          errorMessage: LBL_RetryMessage
        }
      ];
    } finally {
      this.isLoading = false;
    }
  }
}
