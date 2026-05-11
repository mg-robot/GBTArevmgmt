import { LightningElement } from 'lwc';
import PromoCodeWizard from 'c/promoCodeWizard';

/**
 * Temporary launcher card hosted on the Promo Code Home FlexiPage. Opens the
 * PromoCodeWizard modal. Phase 4 replaces this with a list-view button
 * (promoCodeWizardButton) that surfaces on the Promo_Code__c list view itself.
 */
export default class PromoCodeLauncher extends LightningElement {
    async handleOpen() {
        const result = await PromoCodeWizard.open({
            size: 'medium',
            label: 'New Promo Code'
        });
        // Result handling is currently no-op at the launcher level; the wizard
        // itself fires a success toast. List-view refresh hookup lands in Phase 4.
        return result;
    }
}
