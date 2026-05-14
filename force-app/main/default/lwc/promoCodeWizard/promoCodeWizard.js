import LightningModal from "lightning/modal";
import createBulk from "@salesforce/apex/PromoCodeService.createBulk";
import updateBulk from "@salesforce/apex/PromoCodeService.updateBulk";
import getActiveCurrencies from "@salesforce/apex/PromoCodeService.getActiveCurrencies";
import loadDefinition from "@salesforce/apex/PromoCodeService.loadDefinition";
import getDocumentImageUrl from "@salesforce/apex/PromoDocumentIconHelper.getDocumentImageUrl";

import LBL_ModalTitle from "@salesforce/label/c.PromoCodeWizard_Modal_Title";
import LBL_BtnCancel from "@salesforce/label/c.PromoCodeWizard_Btn_Cancel";
import LBL_BtnBack from "@salesforce/label/c.PromoCodeWizard_Btn_Back";
import LBL_BtnNext from "@salesforce/label/c.PromoCodeWizard_Btn_Next";
import LBL_BtnSaveAsDraft from "@salesforce/label/c.PromoCodeWizard_Btn_SaveAsDraft";
import LBL_BtnSaveChanges from "@salesforce/label/c.PromoCodeWizard_Btn_SaveChanges";
import LBL_BtnActivateNow from "@salesforce/label/c.PromoCodeWizard_Btn_ActivateNow";
import LBL_Saving from "@salesforce/label/c.PromoCodeWizard_Saving";
import LBL_CancelConfirm from "@salesforce/label/c.PromoCodeWizard_CancelConfirm";
import LBL_SaveFailed from "@salesforce/label/c.PromoCodeWizard_SaveFailed";
import LBL_EditLockedActive from "@salesforce/label/c.PromoCodeWizard_EditLocked_Active";
import LBL_StepDefinition from "@salesforce/label/c.PromoCodeWizard_Step_Definition";
import LBL_StepScopeEligibility from "@salesforce/label/c.PromoCodeWizard_Step_ScopeEligibility";
import LBL_StepLimitsBehavior from "@salesforce/label/c.PromoCodeWizard_Step_LimitsBehavior";
import LBL_StepReviewActivate from "@salesforce/label/c.PromoCodeWizard_Step_ReviewActivate";

/**
 * Promo Code wizard modal. Opened via PromoCodeWizard.open() from a launcher.
 * 4 steps: Definition / Scope & Eligibility / Limits & Behavior / Review & Activate.
 *
 * Two modes:
 *  - Create (no sourceRecordId): the original flow. Step 4 offers Save as Draft
 *    (Status=Draft) or Activate Now (Status=Active). Apex inserts N records
 *    (one per currency) in a single transaction via createBulk.
 *  - Edit (sourceRecordId set via .open()): used by the "Open in Setup Wizard"
 *    Quick Action on a Draft Promo_Code__c. Loads the record + all currency
 *    siblings, lands on Review, and offers Save Changes (stays Draft) or
 *    Activate Now (flips Draft -> Active). Both call updateBulk, which updates
 *    the existing records in place (no new records created). If the source
 *    record is already Active, the wizard surfaces an error and disables both
 *    save buttons — Active codes are governed by VR_PromoCode_Lock_After_Create
 *    and require the Bypass_Promo_Code_Lock permission to edit.
 *
 * All user-facing text is sourced from Custom Labels for translation via Translation Workbench.
 */
export default class PromoCodeWizard extends LightningModal {
  currentStep = 1;
  isSubmitting = false;
  errorMessage = "";
  availableCurrencies = [];
  iconUrl;

  // Edit-mode state — populated when opened from an existing Promo_Code__c record via the
  // "Open in Setup Wizard" Quick Action. When `sourceRecordId` is passed into .open(),
  // the modal lands on the Review step pre-filled with the record's values (+ currency
  // siblings); Save Changes / Activate Now persist edits to the existing records via
  // updateBulk (no new records are created on this code path).
  sourceRecordId; // set via .open({ sourceRecordId })
  sourceRecordIds = []; // populated by loadDefinition; covers all currency siblings
  mode = "create"; // 'create' | 'edit'
  loadedStatus; // 'Draft' | 'Active' etc., from the source record
  editLocked = false; // true when the source record is Active — disables all save buttons

  // NOTE: must NOT be named `label` — LightningModal already exposes a `label` property
  // (set via .open({ label: ... })) which would shadow our labels object.
  labels = {
    modalTitle: LBL_ModalTitle,
    btnCancel: LBL_BtnCancel,
    btnBack: LBL_BtnBack,
    btnNext: LBL_BtnNext,
    btnSaveAsDraft: LBL_BtnSaveAsDraft,
    btnSaveChanges: LBL_BtnSaveChanges,
    btnActivateNow: LBL_BtnActivateNow,
    saving: LBL_Saving,
    stepDefinition: LBL_StepDefinition,
    stepScopeEligibility: LBL_StepScopeEligibility,
    stepLimitsBehavior: LBL_StepLimitsBehavior,
    stepReviewActivate: LBL_StepReviewActivate
  };

  wizardData = {
    code: "",
    displayName: "",
    terms: "",
    discountType: "",
    percentValue: null,
    percentCurrencies: [],
    amounts: [],
    effectiveStart: "",
    effectiveEnd: "",
    memberTypeScope: [],
    regionScope: [],
    applicationLevel: "Per Order",
    productScopeType: "All Items",
    productFamilyScope: [],
    specificProducts: "",
    accountId: null,
    totalLimit: null,
    perMemberLimit: null,
    combinable: false,
    combinationGroup: "",
    approvalRequired: false,
    applicableTo: "Both",
    minMonthsSinceLastActive: null
  };

  stepValidationStatus = { 1: false, 2: false, 3: false, 4: true };

  connectedCallback() {
    getActiveCurrencies()
      .then((r) => {
        this.availableCurrencies = r || [];
        if (
          this.mode === "create" &&
          this.wizardData.percentCurrencies.length === 0 &&
          this.availableCurrencies.length
        ) {
          this.wizardData = {
            ...this.wizardData,
            percentCurrencies: [...this.availableCurrencies]
          };
        }
      })
      .catch(() => {});
    // Same Document-sourced icon used by the Promo_Code__c tab style.
    getDocumentImageUrl({ documentName: "promo_svg" })
      .then((url) => {
        this.iconUrl = url || null;
      })
      .catch(() => {
        this.iconUrl = null;
      });

    // Edit mode: load the existing record (+ currency siblings) and land on Review.
    if (this.sourceRecordId) {
      this.mode = "edit";
      this.isSubmitting = true;
      loadDefinition({ recordId: this.sourceRecordId })
        .then((def) => {
          if (!def || !def.input) {
            this.errorMessage = "Unable to load promo code definition.";
            return;
          }
          this.wizardData = this.mapInputToWizardData(def.input);
          this.sourceRecordIds = def.sourceRecordIds || [this.sourceRecordId];
          this.loadedStatus = def.currentStatus;
          // The quick action is meant for Draft codes only. If the record is already
          // Active, refuse to edit through the wizard — surface the error and disable
          // both save buttons. The lock VR also blocks the save server-side as a backstop.
          if (this.loadedStatus === "Active") {
            this.editLocked = true;
            this.errorMessage = LBL_EditLockedActive;
          }
          // All steps are valid in edit mode — values came from a previously-saved record.
          this.stepValidationStatus = { 1: true, 2: true, 3: true, 4: true };
          this.currentStep = 4;
        })
        .catch((err) => {
          this.errorMessage =
            (err && err.body && err.body.message) ||
            (err && err.message) ||
            "Failed to load promo code.";
        })
        .finally(() => {
          this.isSubmitting = false;
        });
    }
  }

  mapInputToWizardData(inp) {
    return {
      code: inp.code || "",
      displayName: inp.displayName || "",
      terms: inp.terms || "",
      discountType: inp.discountType || "",
      percentValue: inp.percentValue == null ? null : inp.percentValue,
      percentCurrencies: inp.percentCurrencies || [],
      amounts: inp.amounts || [],
      effectiveStart: inp.effectiveStart || "",
      effectiveEnd: inp.effectiveEnd || "",
      memberTypeScope: inp.memberTypeScope || [],
      regionScope: inp.regionScope || [],
      applicationLevel: inp.applicationLevel || "Per Order",
      productScopeType: inp.productScopeType || "All Items",
      productFamilyScope: inp.productFamilyScope || [],
      specificProducts: inp.specificProducts || "",
      accountId: inp.accountId || null,
      totalLimit: inp.totalLimit == null ? null : inp.totalLimit,
      perMemberLimit: inp.perMemberLimit == null ? null : inp.perMemberLimit,
      combinable: inp.combinable === true,
      combinationGroup: inp.combinationGroup || "",
      approvalRequired: inp.approvalRequired === true,
      applicableTo: inp.applicableTo || "Both",
      minMonthsSinceLastActive:
        inp.minMonthsSinceLastActive == null
          ? null
          : inp.minMonthsSinceLastActive
    };
  }

  get isEditMode() {
    return this.mode === "edit";
  }
  get isCreateMode() {
    return this.mode === "create";
  }
  // "Save as Draft" (create mode) and "Save Changes" (edit mode) share the same
  // button slot in the footer. Both are hidden when the record is edit-locked (Active).
  get showSaveAsDraft() {
    return this.mode === "create";
  }
  get showSaveChanges() {
    return this.mode === "edit" && !this.editLocked;
  }
  get showActivateNow() {
    return !this.editLocked;
  }
  get saveButtonsDisabled() {
    return this.isSubmitting || this.editLocked;
  }

  handleIconError() {
    this.iconUrl = null;
  }

  get hasIconUrl() {
    return !!this.iconUrl;
  }

  get isStep1() {
    return this.currentStep === 1;
  }
  get isStep2() {
    return this.currentStep === 2;
  }
  get isStep3() {
    return this.currentStep === 3;
  }
  get isStep4() {
    return this.currentStep === 4;
  }
  get isFirstStep() {
    return this.currentStep === 1;
  }
  get isReviewStep() {
    return this.currentStep === 4;
  }
  get nextDisabled() {
    return !this.stepValidationStatus[this.currentStep];
  }

  get progressSteps() {
    const defs = [
      { step: 1, label: this.labels.stepDefinition },
      { step: 2, label: this.labels.stepScopeEligibility },
      { step: 3, label: this.labels.stepLimitsBehavior },
      { step: 4, label: this.labels.stepReviewActivate }
    ];
    return defs.map((d, idx) => {
      const isCompleted = d.step < this.currentStep;
      const isActive = d.step === this.currentStep;
      const isLast = idx === defs.length - 1;
      let cls = "pcw-step";
      if (isCompleted) cls += " pcw-step--completed";
      else if (isActive) cls += " pcw-step--active";
      else cls += " pcw-step--upcoming";
      if (isLast) cls += " pcw-step--last";
      return {
        step: d.step,
        label: d.label,
        containerClass: cls,
        ariaCurrent: isActive ? "step" : null
      };
    });
  }

  handleStepClick(event) {
    const stepNum = parseInt(event.currentTarget.dataset.step, 10);
    if (!isNaN(stepNum) && stepNum < this.currentStep) {
      this.currentStep = stepNum;
      this.errorMessage = "";
    }
  }

  handleFieldChange(event) {
    const { field, value } = event.detail;
    this.wizardData = { ...this.wizardData, [field]: value };
  }

  handleStepValidate(event) {
    this.stepValidationStatus = {
      ...this.stepValidationStatus,
      [this.currentStep]: !!event.detail.valid
    };
  }

  handleNext() {
    if (!this.stepValidationStatus[this.currentStep]) return;
    if (this.currentStep < 4) {
      this.currentStep += 1;
      this.errorMessage = "";
    }
  }

  handleBack() {
    if (this.currentStep > 1) {
      this.currentStep -= 1;
      this.errorMessage = "";
    }
  }

  handleProgressClick(event) {
    const value = event && event.detail && event.detail.value;
    if (!value) return;
    const targetStep = parseInt(String(value).replace("step", ""), 10);
    if (!isNaN(targetStep) && targetStep < this.currentStep) {
      this.currentStep = targetStep;
      this.errorMessage = "";
    }
  }

  handleJumpTo(event) {
    const targetStep = parseInt(event.detail.step, 10);
    if (!isNaN(targetStep) && targetStep >= 1 && targetStep <= 4) {
      this.currentStep = targetStep;
    }
  }

  handleCancel() {
    // In edit mode the data was pre-loaded from the record, so a cancel is just
    // "close without saving" — no need to prompt. The hasData guard below is for
    // create-mode where it protects against losing freshly-entered values.
    const hasData =
      this.mode === "create" &&
      (this.wizardData.code ||
        this.wizardData.displayName ||
        this.wizardData.discountType);
    if (hasData) {
      // eslint-disable-next-line no-alert
      if (!window.confirm(LBL_CancelConfirm)) {
        return;
      }
    }
    this.close({ result: "cancelled" });
  }

  handleSaveDraft() {
    if (this.editLocked) return;
    if (this.mode === "edit") {
      this.submitUpdate(false);
    } else {
      this.submit(false);
    }
  }
  handleActivateNow() {
    if (this.editLocked) return;
    if (this.mode === "edit") {
      this.submitUpdate(true);
    } else {
      this.submit(true);
    }
  }

  buildInputFromWizardData(activate) {
    const w = this.wizardData || {};
    const isPercent = w.discountType === "Percent";
    const isAmount = w.discountType === "Amount";
    const input = {
      code: w.code,
      displayName: w.displayName,
      terms: w.terms,
      discountType: w.discountType,
      percentValue: isPercent ? w.percentValue : null,
      percentCurrencies: isPercent ? w.percentCurrencies : null,
      amounts: isAmount ? w.amounts : null,
      effectiveStart: w.effectiveStart || null,
      effectiveEnd: w.effectiveEnd || null,
      totalLimit:
        w.totalLimit === "" || w.totalLimit == null ? null : w.totalLimit,
      perMemberLimit:
        w.perMemberLimit === "" || w.perMemberLimit == null
          ? null
          : w.perMemberLimit,
      memberTypeScope: w.memberTypeScope,
      regionScope: w.regionScope,
      applicationLevel: w.applicationLevel,
      productScopeType: w.productScopeType,
      productFamilyScope: w.productFamilyScope,
      specificProducts: w.specificProducts,
      accountId: w.accountId,
      combinable: w.combinable,
      combinationGroup: w.combinationGroup,
      approvalRequired: w.approvalRequired,
      applicableTo: w.applicableTo || "Both",
      minMonthsSinceLastActive:
        w.minMonthsSinceLastActive === "" || w.minMonthsSinceLastActive == null
          ? null
          : w.minMonthsSinceLastActive,
      activateImmediately: activate
    };
    return JSON.parse(JSON.stringify(input));
  }

  submitUpdate(activate) {
    if (!this.sourceRecordIds || !this.sourceRecordIds.length) {
      this.errorMessage = "No records to update.";
      return;
    }
    this.isSubmitting = true;
    this.errorMessage = "";
    const cleanInput = this.buildInputFromWizardData(activate);
    updateBulk({
      input: cleanInput,
      recordIds: this.sourceRecordIds,
      activate: activate === true
    })
      .then((r) => {
        if (r && r.success) {
          try {
            this.close(activate ? "activated" : "updated");
          } catch {
            try {
              this.close();
            } catch {
              /* swallow */
            }
          }
        } else {
          this.errorMessage = (r && r.errorMessage) || LBL_SaveFailed;
          if (r && r.conflictCurrencies && r.conflictCurrencies.length) {
            this.currentStep = 1;
          }
        }
      })
      .catch((err) => {
        this.errorMessage =
          (err && err.body && err.body.message) ||
          (err && err.message) ||
          LBL_SaveFailed;
      })
      .finally(() => {
        this.isSubmitting = false;
      });
  }

  submit(activate) {
    this.isSubmitting = true;
    this.errorMessage = "";
    const cleanInput = this.buildInputFromWizardData(activate);
    createBulk({ input: cleanInput })
      .then((r) => {
        if (r && r.success) {
          try {
            this.close("created");
          } catch {
            try {
              this.close();
            } catch {
              /* swallow */
            }
          }
        } else {
          this.errorMessage = (r && r.errorMessage) || LBL_SaveFailed;
          if (r && r.conflictCurrencies && r.conflictCurrencies.length) {
            this.currentStep = 1;
          }
        }
      })
      .catch((err) => {
        this.errorMessage =
          (err && err.body && err.body.message) ||
          (err && err.message) ||
          LBL_SaveFailed;
      })
      .finally(() => {
        this.isSubmitting = false;
      });
  }
}
