import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PromoCodeWizard from 'c/promoCodeWizard';

/**
 * Launcher card on the Promotions Home FlexiPage. Opens the PromoCodeWizard modal.
 * After the modal closes successfully, shows a toast with the count and action — the
 * toast must fire from the launcher (not the modal) because LightningModal doesn't
 * surface ShowToastEvent.
 */
export default class PromoCodeLauncher extends LightningElement {
    async handleOpen() {
        const result = await PromoCodeWizard.open({
            size: 'medium',
            label: 'New Promo Code'
        });
        if (result && result.result === 'created') {
            const count = result.count || 0;
            const action = result.action || 'created';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Promo Code',
                message: `${count} promo code${count === 1 ? '' : 's'} ${action}.`,
                variant: 'success'
            }));
        }
    }
}
