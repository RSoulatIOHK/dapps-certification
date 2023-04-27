import { useEffect, useState, useCallback } from "react";
import { Address } from "@emurgo/cardano-serialization-lib-browser";
import { useAppDispatch } from "store/store";
import { getProfileDetails, setNetwork } from "store/slices/auth.slice";

import Modal from "components/Modal/Modal";
import Button from "components/Button/Button";
import Loader from "components/Loader/Loader";

import './ConnectWallet.scss';

const wallets: Array<string> = ['lace', 'nami', 'yoroi']

declare global {
    interface Window {
        cardano:any;
    }
}
let CardanoNS = window.cardano;

const ConnectWallet = () => {
    const dispatch = useAppDispatch();
    const [wallet, setWallet] = useState(null)
    const [walletName, setWalletName] = useState("")
    const [address, setAddress] = useState("")
    const [isOpen, setIsOpen] = useState(false)
    const [errorToast, setErrorToast] = useState<{display: boolean; statusText?: string; message?: string;}>({display: false});
    const [walletLoading, setWalletLoading] = useState(false)

    const openConnectWalletModal = useCallback(() => setIsOpen(true),[])

    const onCloseModal = useCallback(() => setIsOpen(false),[]) 

    const loadWallet = async (walletName: string) => {
        try {
            setWalletLoading(true)
            const enabledWallet = await CardanoNS[walletName].enable();
            enabledWallet.getNetworkId().then(async (data: number) => {
                dispatch(setNetwork(data))
                setWallet(enabledWallet)
                setWalletName(walletName)
                if (enabledWallet) {
                    const response = await enabledWallet.getChangeAddress()
                    setAddress(Address.from_bytes(Buffer.from(response, "hex")).to_bech32())
                }
            })
        } catch (e) { handleError(e); }
    }

    const handleError = (error: any) => {
        if (error.info) {
            setErrorToast({display: true, message: error.info})
        } else if (error.response) {
          setErrorToast({display: true, statusText: error.response.statusText, message: error.response.data || undefined})
        } else {
          setErrorToast({display: true})
        }
        setTimeout(() => { setErrorToast({display: false}) }, 3000)
    }

    useEffect(() => {
        if (address) {
            (async () => {
                try {
                    await dispatch(getProfileDetails({"address": address, "wallet": wallet, "walletName": walletName})).catch(handleError)
                    setWalletLoading(false)
                } catch(error) {
                    setWalletLoading(false)
                    handleError(error)
                    // dispatch(clearCache()) 
                }
            })()
        }
    }, [dispatch, address, wallet, walletName])

    return (
        <>
            <Button
                type="button"
                displayStyle="gradient"
                buttonLabel={"Connect Wallet"}
                onClick={openConnectWalletModal}
            />
            <Modal open={isOpen} title="Connect a wallet" onCloseModal={onCloseModal}>
                <div id="walletsContainer">
                    {wallet ? 
                        null : !CardanoNS ? (<span>No wallet extensions installed yet!</span>) :
                        wallets.map((wallet: string, index: number) => {
                            if (CardanoNS && CardanoNS[wallet]) {
                                return (
                                    <div className="card" key={index} onClick={(_) => loadWallet(wallet)}>
                                        <img src={CardanoNS[wallet].icon} alt={CardanoNS[wallet].name} />
                                        <span>{CardanoNS[wallet].name}</span>
                                    </div>
                                )
                            } else {
                                return null
                            }
                        })
                    }
                    { walletLoading ? <Loader /> : null}
                    {
                        (errorToast && errorToast.display) ? (<span className="error">{errorToast.message}</span>): null
                    }
                </div>
            </Modal>
            {/* {(errorToast && errorToast.display) ? (
                ((errorToast.message && errorToast.statusText) ? 
                <Toast message={errorToast.message} title={errorToast.statusText}/> :
                <Toast />))
            : null} */}
        </>
    )
}

export default ConnectWallet;