import { LightningElement, api, wire, track } from "lwc";
import { getPicklistValues } from "lightning/uiObjectInfoApi";

import MEMBER_TYPE_SCOPE_FIELD from "@salesforce/schema/Promo_Code__c.Member_Type_Scope__c";
import REGION_SCOPE_FIELD from "@salesforce/schema/Promo_Code__c.Region_Scope__c";
import APPLICABLE_TO_FIELD from "@salesforce/schema/Promo_Code__c.Applicable_To__c";

import LBL_ValidityHeading from "@salesforce/label/c.PromoCodeWizard_S2_Validity_Heading";
import LBL_EffectiveStart from "@salesforce/label/c.PromoCodeWizard_S2_EffectiveStart_Label";
import LBL_EffectiveEnd from "@salesforce/label/c.PromoCodeWizard_S2_EffectiveEnd_Label";
import LBL_MemberTypeScope from "@salesforce/label/c.PromoCodeWizard_S2_MemberType_Label";
import LBL_RegionScope from "@salesforce/label/c.PromoCodeWizard_S2_Region_Label";
import LBL_ProductAppHeading from "@salesforce/label/c.PromoCodeWizard_S2_ProductApp_Heading";
import LBL_AccountScopeHeading from "@salesforce/label/c.PromoCodeWizard_S2_AccountScope_Heading";
import LBL_AccountScopeHelper from "@salesforce/label/c.PromoCodeWizard_S2_AccountScope_Helper";
import LBL_Account from "@salesforce/label/c.PromoCodeWizard_S2_Account_Label";
import LBL_FlowAppHeading from "@salesforce/label/c.PromoCodeWizard_S2_FlowApp_Heading";
import LBL_FlowAppHelper from "@salesforce/label/c.PromoCodeWizard_S2_FlowApp_Helper";
import LBL_ApplicableTo from "@salesforce/label/c.PromoCodeWizard_S2_ApplicableTo_Label";
import LBL_MinMonths from "@salesforce/label/c.PromoCodeWizard_S2_MinMonths_Label";
import LBL_MinMonthsHelper from "@salesforce/label/c.PromoCodeWizard_S2_MinMonths_Helper";

const MASTER_RT = "012000000000000AAA";

// Helper micro-copy
const VALIDITY_HELPER =
  "Set when this code is valid. After the end date passes, members will see an 'this code is not valid right now' message at checkout — the code stays Active in the system but won't apply.";
const REGION_HELPER =
  "Leave Region Scope blank to make this code available in all regions.";
const PRODUCT_APP_HELPER =
  "Choose which membership product lines this code discounts. The full discount value will be applied to each eligible line.";
const SELECT_ALL_LABEL = "Select All Membership Types";

/**
 * Step 2 of the wizard — Scope & Eligibility.
 * Sections:
 *   1. Validity Window
 *   2. Region
 *   3. Product Applicability (membership types only — at least one required)
 *   4. Account Scope
 *   5. Flow Applicability (Join / Renew / Both + optional lookback)
 *
 * Application Level is not shown — discounts always apply Per Line to membership products.
 */
export default class PromoCodeWizardStepScope extends LightningElement {
  @api wizardData;

  @track _memberTypeOptions = [];
  @track _regionOptions = [];
  @track _applicableToOptions = [];

  label = {
    validityHeading: LBL_ValidityHeading,
    validityHelper: VALIDITY_HELPER,
    effectiveStart: LBL_EffectiveStart,
    effectiveEnd: LBL_EffectiveEnd,
    regionHeading: "Region",
    regionHelper: REGION_HELPER,
    memberTypeScope: LBL_MemberTypeScope,
    regionScope: LBL_RegionScope,
    productAppHeading: LBL_ProductAppHeading,
    productAppHelper: PRODUCT_APP_HELPER,
    selectAll: SELECT_ALL_LABEL,
    accountScopeHeading: LBL_AccountScopeHeading,
    accountScopeHelper: LBL_AccountScopeHelper,
    account: LBL_Account,
    flowAppHeading: LBL_FlowAppHeading,
    flowAppHelper: LBL_FlowAppHelper,
    applicableTo: LBL_ApplicableTo,
    minMonths: LBL_MinMonths,
    minMonthsHelper: LBL_MinMonthsHelper
  };

  @wire(getPicklistValues, {
    recordTypeId: MASTER_RT,
    fieldApiName: MEMBER_TYPE_SCOPE_FIELD
  })
  wiredMemberType({ data }) {
    if (data)
      this._memberTypeOptions = data.values.map((v) => ({
        label: v.label,
        value: v.value
      }));
  }
  @wire(getPicklistValues, {
    recordTypeId: MASTER_RT,
    fieldApiName: REGION_SCOPE_FIELD
  })
  wiredRegion({ data }) {
    if (data)
      this._regionOptions = data.values.map((v) => ({
        label: v.label,
        value: v.value
      }));
  }
  @wire(getPicklistValues, {
    recordTypeId: MASTER_RT,
    fieldApiName: APPLICABLE_TO_FIELD
  })
  wiredApplicableTo({ data }) {
    if (data)
      this._applicableToOptions = data.values.map((v) => ({
        label: v.label,
        value: v.value
      }));
  }

  get memberTypeOptions() {
    return this._memberTypeOptions;
  }
  get regionOptions() {
    return this._regionOptions;
  }
  get applicableToOptions() {
    return this._applicableToOptions;
  }
  // Min Months only makes sense when the code is valid for the Join flow.
  get minMonthsApplies() {
    const v = this.wizardData?.applicableTo;
    return !v || v === "Both" || v === "Join";
  }

  get selectAllChecked() {
    const opts = this._memberTypeOptions;
    const selected = this.wizardData?.memberTypeScope || [];
    return opts.length > 0 && selected.length === opts.length;
  }

  connectedCallback() {
    // Normalize legacy 'All Items' records to the only supported scope value
    if (this.wizardData?.productScopeType !== "Specific Membership Types") {
      this.dispatch("productScopeType", "Specific Membership Types");
    }
    Promise.resolve().then(() => this.fireValidate());
  }

  handleStartChange(e) {
    this.dispatch("effectiveStart", e.target.value);
  }
  handleEndChange(e) {
    this.dispatch("effectiveEnd", e.target.value);
  }
  handleRegionScopeChange(e) {
    this.dispatch("regionScope", e.detail.value);
  }

  handleSelectAllChange(e) {
    const allValues = e.target.checked
      ? this._memberTypeOptions.map((o) => o.value)
      : [];
    this.dispatch("memberTypeScope", allValues);
  }

  handleMemberTypeScopeChange(e) {
    this.dispatch("memberTypeScope", e.detail.value);
  }
  handleAccountChange(e) {
    this.dispatch("accountId", e.detail.recordId || null);
  }
  handleApplicableToChange(e) {
    const v = e.detail.value;
    this.dispatch("applicableTo", v);
    // Min Months is Join-only — clear it if the user switches the code to Renew-only.
    if (v === "Renew") {
      this.dispatch("minMonthsSinceLastActive", null);
    }
  }
  handleMinMonthsChange(e) {
    const raw = e.target.value;
    const num = raw === "" || raw == null ? null : Number(raw);
    this.dispatch("minMonthsSinceLastActive", num);
  }

  dispatch(field, value) {
    this.dispatchEvent(
      new CustomEvent("fieldchange", { detail: { field, value } })
    );
    Promise.resolve().then(() => this.fireValidate());
  }

  fireValidate() {
    const d = this.wizardData || {};
    let valid = true;
    // Validity Window: end must be after start when both set
    if (d.effectiveStart && d.effectiveEnd) {
      if (new Date(d.effectiveEnd) <= new Date(d.effectiveStart)) valid = false;
    }
    // Required fields
    if (!d.effectiveStart) valid = false;
    if (!d.applicableTo) valid = false;
    // At least one membership type must be selected
    if (!d.memberTypeScope || d.memberTypeScope.length === 0) valid = false;
    // Min Months must be a non-negative integer when present; only meaningful for Join codes.
    if (
      d.minMonthsSinceLastActive != null &&
      d.minMonthsSinceLastActive !== ""
    ) {
      const n = Number(d.minMonthsSinceLastActive);
      if (!Number.isFinite(n) || n < 0 || !Number.isInteger(n)) valid = false;
      if (d.applicableTo === "Renew") valid = false;
    }
    this.dispatchEvent(new CustomEvent("stepvalidate", { detail: { valid } }));
  }
}
