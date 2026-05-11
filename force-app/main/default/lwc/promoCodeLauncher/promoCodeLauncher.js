import { LightningElement } from 'lwc';
import PromoCodeWizard from 'c/promoCodeWizard';

/**
 * Launcher card on the Promotions Home FlexiPage. Opens the PromoCodeWizard modal.
 * (Toast suppressed for now while we trace a dispatchEvent error path.)
 */
export default class PromoCodeLauncher extends LightningElement {
    async handleOpen() {
        try {
            await PromoCodeWizard.open({
                size: 'medium',
                label: 'New Promo Code'
            });
        } catch (e) {
            // swallow
        }
    }
}
