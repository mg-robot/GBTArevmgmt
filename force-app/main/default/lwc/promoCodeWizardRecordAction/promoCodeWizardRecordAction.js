import { LightningElement, api } from "lwc";
import PromoCodeWizard from "c/promoCodeWizard";

import LBL_ModalTitle from "@salesforce/label/c.PromoCodeWizard_Modal_Title";

/**
 * Headless Lightning Quick Action — when invoked from a Promo_Code__c record page, opens
 * the existing PromoCodeWizard modal in "edit" mode pre-filled with the record's values
 * (plus any currency siblings sharing the same Code__c) and landing on the Review step.
 *
 * Invoked by the platform via invoke() per the LWC Quick Action contract. recordId is
 * auto-injected by the Lightning runtime.
 */
export default class PromoCodeWizardRecordAction extends LightningElement {
  @api recordId;

  @api async invoke() {
    if (!this.recordId) return;
    try {
      await PromoCodeWizard.open({
        size: "medium",
        label: LBL_ModalTitle,
        sourceRecordId: this.recordId
      });
    } catch {
      // Swallow — modal close is not an error path.
    }
  }
}
