import { LightningElement, api } from "lwc";
import LightningAlert from "lightning/alert";
import PromoCodeWizard from "c/promoCodeWizard";
import getRecordStatus from "@salesforce/apex/PromoCodeService.getRecordStatus";

import LBL_ModalTitle from "@salesforce/label/c.PromoCodeWizard_Modal_Title";
import LBL_EditLockedActive from "@salesforce/label/c.PromoCodeWizard_EditLocked_Active";

/**
 * Headless Lightning Quick Action — when invoked from a Promo_Code__c record page, opens
 * the existing PromoCodeWizard modal in "edit" mode pre-filled with the record's values
 * (plus any currency siblings sharing the same Code__c) and landing on the Review step.
 *
 * The action is intended only for Draft codes: if the record is already Active we
 * short-circuit before opening the modal and show a LightningAlert explaining why.
 * The action itself can also be hidden via Dynamic Actions on the record page
 * (visibility rule `Status__c != 'Active'`) — this runtime check is the backstop.
 *
 * Invoked by the platform via invoke() per the LWC Quick Action contract. recordId is
 * auto-injected by the Lightning runtime.
 */
export default class PromoCodeWizardRecordAction extends LightningElement {
  @api recordId;

  @api async invoke() {
    if (!this.recordId) return;
    try {
      const status = await getRecordStatus({ recordId: this.recordId });
      if (status === "Active") {
        await LightningAlert.open({
          message: LBL_EditLockedActive,
          theme: "warning",
          label: LBL_ModalTitle
        });
        return;
      }
      await PromoCodeWizard.open({
        size: "medium",
        label: LBL_ModalTitle,
        sourceRecordId: this.recordId
      });
    } catch {
      // Swallow — modal close is not an error path; status-fetch errors are surfaced
      // by the modal's own load step (loadDefinition) if we still attempt to open.
    }
  }
}
