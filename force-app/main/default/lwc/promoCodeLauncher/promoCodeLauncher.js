import { LightningElement } from 'lwc';
import PromoCodeWizard from 'c/promoCodeWizard';

import LBL_BtnNew from '@salesforce/label/c.PromoCodeWizard_Launcher_Btn_New';
import LBL_Helper from '@salesforce/label/c.PromoCodeWizard_Launcher_Helper';
import LBL_ModalTitle from '@salesforce/label/c.PromoCodeWizard_Modal_Title';

/**
 * Launcher card on the Promotions Home FlexiPage. Opens the PromoCodeWizard modal.
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
                size: 'medium',
                label: LBL_ModalTitle
            });
        } catch (e) {
            // swallow
        }
    }
}
