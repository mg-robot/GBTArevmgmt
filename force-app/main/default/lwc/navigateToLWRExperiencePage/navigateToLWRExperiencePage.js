import { api, LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

export default class navigateToLWRExperiencePage extends NavigationMixin(LightningElement) {
    @api
    apiPageName;

    doRedirect() {
        let pageRef = {
            type: 'comm__namedPage',
            attributes: {
                name: this.apiPageName
            }, state: {}
        };
        console.log('redirecting...', JSON.stringify(pageRef));
        this[NavigationMixin.Navigate](pageRef);
    }

    connectedCallback() {
        this.doRedirect();
    }

}