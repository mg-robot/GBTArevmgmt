import { LightningElement } from "lwc";
import PromoCodeWizard from "c/promoCodeWizard";

import LBL_BtnNew from "@salesforce/label/c.PromoCodeWizard_Launcher_Btn_New";
import LBL_Helper from "@salesforce/label/c.PromoCodeWizard_Launcher_Helper";
import LBL_ModalTitle from "@salesforce/label/c.PromoCodeWizard_Modal_Title";

/**
 * Launcher card on the Promotions Home FlexiPage. Opens the PromoCodeWizard modal.
 * Renders as a clickable setup-card row matching the Revenue Cloud Setup home style.
 * All user-facing text is sourced from Custom Labels.
 */
export default class PromoCodeLauncher extends LightningElement {
  label = {
    btnNew: LBL_BtnNew,
    helper: LBL_Helper
  };

  async handleOpen() {
    try {
      await PromoCodeWizard.open({
        size: "medium",
        label: LBL_ModalTitle
      });
    } catch {
      // Modal close is not an error path.
    }
  }

  handleKeydown(e) {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      this.handleOpen();
    }
  }
}
