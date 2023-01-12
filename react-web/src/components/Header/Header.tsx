import React, { useEffect, useState, memo, useCallback } from "react";
import { useNavigate, Link } from "react-router-dom";
import { useAppDispatch, useAppSelector } from "store/store";
import { logout } from "store/slices/auth.slice";
import "./Header.scss";

import AvatarDropDown from "components/AvatarDropdown/AvatarDropdown";
import ConnectWallet from "components/ConnectWallet/ConnectWallet";
import { useDelayedApi } from "hooks/useDelayedApi";

const Header = () => {
  const { isLoggedIn, address, wallet } = useAppSelector((state) => state.auth);
  const dispatch = useAppDispatch();
  const [isActive, setIsActive] = useState(false);
  const [pollForAddress, setPollForAddress] = useState(false);
  const navigate = useNavigate();

  useEffect(() => {
    if (isLoggedIn) {
      navigate("/");
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isLoggedIn]);

  useEffect(() => {
    setPollForAddress(wallet && address && isLoggedIn);
  }, [wallet, address, isLoggedIn]);

  useDelayedApi(
    async () => {
      setPollForAddress(false);
      const newAddress = wallet ? await wallet.getChangeAddress() : null;
      if (newAddress && address !== newAddress) {
        // account has been changed. Force logout the user
        dispatch(logout());
        setPollForAddress(false);
      } else {
        setPollForAddress(true);
      }
    },
    3 * 1000,
    pollForAddress
  );

  const NoAuthMenu = memo(() => {
    return (
      <>
        <li>
          <Link to="community">Community</Link>
        </li>
        <li>
          <Link to="pricing">Pricing</Link>
        </li>
        <li>
          <Link to="support">Support</Link>
        </li>
        <li className="button-wrap">
          <ConnectWallet />
        </li>
      </>
    );
  });
  const AuthenticatedMenu = memo(() => {
    return (
      <>
        <li>
          <Link to="support">Support</Link>
        </li>
        <li>
          <Link to="subscription">Subscription</Link>
        </li>
        {/*
        <li>
          <Link to="test">Test History</Link>
        </li>
        */}
        <li>
          <AvatarDropDown />
        </li>
      </>
    );
  });

  const ProfileSection = useCallback(() => {
    return (
      <ul className={`menu ${isActive ? "active-ul" : ""}`}>
        {isLoggedIn ? <AuthenticatedMenu /> : <NoAuthMenu />}
      </ul>
    );
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isActive, isLoggedIn]);

  return (
    <header className="header">
      <Link to="/">
        <img
          src="images/logo.png"
          alt="IOHK logo"
          style={{ width: "82px", padding: "10px" }}
        />
      </Link>

      <input
        className="menu-btn"
        type="checkbox"
        id="menu-btn"
        onChange={(e) => setIsActive(!isActive)}
      />
      <label className="menu-icon" htmlFor="menu-btn">
        <span className="navicon"></span>
      </label>
      <ProfileSection />
    </header>
  );
};

export default Header;
